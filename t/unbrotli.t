#!/usr/bin/perl

# Tests for ngx_http_unbrotli_filter_module.

###############################################################################

use warnings;
use strict;

use IO::Socket::INET;
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx qw/ :DEFAULT :gzip http_content /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http gzip proxy ssi/)
    ->has_daemon('brotli')->plan(42);

my $plain = join('', map { sprintf "X%03dXXXXXX", $_ } (0 .. 999));
my $boundary = 'B' x 1024;

my $encoded = brotli_file($t, 'basic', $plain);
my $first = brotli_file($t, 'first', 'first-stream:');
my $second = brotli_file($t, 'second', 'second-stream');
my $empty = brotli_file($t, 'empty', '');
my $boundary_encoded = brotli_file($t, 'boundary', $boundary);

$t->write_file('concat', $first . $second);
$t->write_file('trailing', $encoded . 'not-a-brotli-stream');
$t->write_file('truncated', substr($encoded, 0, length($encoded) - 3));
$t->write_file('corrupt', "\xff" x 16);
$t->write_file('missing-stream', '');
$t->write_file('identity', 'identity response');
$t->write_file('page.html',
    'before <!--# include virtual="/basic" --> after');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    gzip_vary on;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /force {
            unbrotli on;
            unbrotli_force on;
            proxy_pass http://127.0.0.1:8081/basic;
        }

        location = /gzip {
            unbrotli on;
            gzip on;
            gzip_min_length 0;
            gzip_http_version 1.0;
            gzip_types text/plain;
            proxy_pass http://127.0.0.1:8081/basic;
        }

        location = /stream {
            unbrotli on;
            unbrotli_buffers 2 1k;
            proxy_buffering off;
            proxy_pass http://127.0.0.1:8082/;
        }

        location = /stream-trailing {
            unbrotli on;
            proxy_buffering off;
            proxy_pass http://127.0.0.1:8083/;
        }

        location = /page.html {
            ssi on;
            root %%TESTDIR%%;
        }

        location = /error {
            error_page 500 = /basic;
            return 500;
        }

        location / {
            unbrotli on;
            proxy_pass http://127.0.0.1:8081;
        }
    }

    server {
        listen       127.0.0.1:8081;
        server_name  localhost;

        location = /identity {
            root %%TESTDIR%%;
        }

        location / {
            root %%TESTDIR%%;
            default_type text/plain;
            etag off;
            add_header Content-Encoding br always;
            add_header ETag '"strong"' always;
        }
    }
}

EOF

$t->run_daemon(\&stream_daemon, port(8082), $boundary_encoded);
$t->run_daemon(\&stream_daemon, port(8083),
    $encoded . 'split-trailing-data');
$t->run();

###############################################################################

my $r = get('/basic');
unlike($r, qr/^Content-Encoding:/mi, 'content encoding removed');
is(http_content($r), $plain, 'response decompressed');
unlike($r, qr/^Content-Length:/mi, 'content length removed');
unlike($r, qr/^Accept-Ranges:/mi, 'accept ranges removed');
like($r, qr/^ETag: W\/"strong"/mi, 'etag weakened');
like($r, qr/^Vary: Accept-Encoding/mi, 'vary added');

$r = get('/basic', 'br');
like($r, qr/^Content-Encoding: br/mi, 'accepted encoding preserved');
is(http_content($r), $encoded, 'accepted body preserved');

$r = get('/basic', 'br;q=0');
is(http_content($r), $plain, 'q zero decompressed');

$r = get('/basic', 'brx');
is(http_content($r), $plain, 'coding prefix rejected');

$r = get('/basic', 'br, gzip');
like($r, qr/^Content-Encoding: br/mi, 'fast path accepted');

$r = get('/basic', 'BR');
like($r, qr/^Content-Encoding: br/mi, 'coding is case insensitive');

$r = get('/basic', 'br;q=0.001');
like($r, qr/^Content-Encoding: br/mi, 'positive minimum q accepted');

$r = get('/basic', 'br;q=0.000');
is(http_content($r), $plain, 'zero fractional q decompressed');

$r = get('/basic', 'br;q=1.001');
is(http_content($r), $plain, 'invalid q decompressed');

$r = get('/basic', 'br;');
like($r, qr/^Content-Encoding: br/mi,
    'trailing semicolon follows gzip parser behavior');

$r = get('/force', 'br');
unlike($r, qr/^Content-Encoding:/mi, 'force removes encoding');
is(http_content($r), $plain, 'force decompresses accepted encoding');

$r = get('/gzip', 'br, gzip');
like($r, qr/^Content-Encoding: br/mi,
    'accepted brotli is not recompressed');
is(http_content($r), $encoded,
    'accepted brotli body is preserved with gzip on');

$r = http_gzip_request('/gzip');
like($r, qr/^Content-Encoding: gzip/mi,
    'gzip still works after brotli decompression');
http_gzip_like($r, qr/^\Q$plain\E$/,
    'brotli response is recompressed for gzip client');

$r = get('/empty');
like($r, qr/ 200 /, 'empty stream status');
is(http_content($r), '', 'empty stream decompressed');

$r = get('/stream');
like($r, qr/ 200 /, 'chunked boundary status');
is(http_content($r), $boundary,
    'chunked stream ending before final buffer decompressed');

$r = get('/page.html');
unlike($r, qr/^Content-Encoding:/mi, 'ssi response is not encoded');
is(http_content($r), "before $plain after", 'ssi subrequest decompressed');

$r = get('/identity');
is(http_content($r), 'identity response', 'identity response preserved');
unlike($r, qr/^Vary:/mi, 'identity response has no vary');

$r = head('/basic');
unlike($r, qr/^Content-Encoding:/mi, 'head content encoding removed');
unlike($r, qr/^Content-Length:/mi, 'head content length removed');
like($r, qr/^Vary: Accept-Encoding/mi, 'head vary added');

is(http_content(get('/error')), $plain,
    'response after internal redirect decompressed');

$r = get('/truncated');
like($t->read_file('error.log'),
    qr/BrotliDecoderDecompressStream\(\) returned \d+ on response end/,
    'truncated stream rejected');

my $errors = decoder_error_count($t);
$r = get('/corrupt');
cmp_ok(decoder_error_count($t), '>', $errors, 'corrupt stream rejected');

$errors = trailing_error_count($t);
$r = get('/trailing');
cmp_ok(trailing_error_count($t), '>', $errors, 'trailing data rejected');

$errors = trailing_error_count($t);
$r = get('/concat');
cmp_ok(trailing_error_count($t), '>', $errors,
    'concatenated streams rejected');

$errors = trailing_error_count($t);
$r = get('/stream-trailing');
cmp_ok(trailing_error_count($t), '>', $errors,
    'trailing data in a later buffer rejected');

$errors = response_end_error_count($t);
$r = get('/missing-stream');
cmp_ok(response_end_error_count($t), '>', $errors,
    'missing stream rejected');

like($t->read_file('error.log'), qr/http unbrotli filter/,
    'body filter exercised');
unlike($t->read_file('error.log'), qr/worker process exited on signal/,
    'worker remained healthy');

###############################################################################

sub get {
    my ($uri, $accept_encoding) = @_;
    my $header = defined $accept_encoding
        ? "Accept-Encoding: $accept_encoding\r\n" : '';

    return http("GET $uri HTTP/1.0\r\n"
        . "Host: localhost\r\n"
        . $header
        . "Connection: close\r\n\r\n");
}


sub head {
    my ($uri) = @_;

    return http("HEAD $uri HTTP/1.0\r\n"
        . "Host: localhost\r\n"
        . "Connection: close\r\n\r\n");
}


sub brotli_file {
    my ($test, $name, $content) = @_;
    my $source = "$name.source";
    my $testdir = $test->testdir();

    $test->write_file($source, $content);

    system('brotli', '-f', '-q', '5', "$testdir/$source",
           '-o', "$testdir/$name") == 0
        or die "brotli failed for $name: $?";

    return $test->read_file($name);
}


sub decoder_error_count {
    my ($test) = @_;
    my $log = $test->read_file('error.log');

    return () = $log =~ /BrotliDecoderDecompressStream\(\) failed/g;
}


sub trailing_error_count {
    my ($test) = @_;
    my $log = $test->read_file('error.log');

    return () = $log =~ /brotli stream has \d+ trailing bytes/g;
}


sub response_end_error_count {
    my ($test) = @_;
    my $log = $test->read_file('error.log');

    return () = $log
        =~ /BrotliDecoderDecompressStream\(\) returned \d+ on response end/g;
}


sub stream_daemon {
    my ($port, $content) = @_;

    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => $port,
        Listen => 5,
        ReuseAddr => 1,
        Proto => 'tcp'
    ) or die "cannot create stream test server: $!";

    while (my $client = $server->accept()) {
        $client->autoflush(1);

        my $request = '';
        while ($request !~ /\r?\n\r?\n/) {
            my $n = sysread($client, my $buffer, 1024);
            last if !defined $n || $n == 0;
            $request .= $buffer;
        }

        print $client "HTTP/1.1 200 OK\r\n"
            . "Content-Type: text/plain\r\n"
            . "Content-Encoding: br\r\n"
            . "Transfer-Encoding: chunked\r\n"
            . "Connection: close\r\n\r\n";

        for my $byte (split //, $content) {
            print $client "1\r\n$byte\r\n";
            select undef, undef, undef, 0.001;
        }

        select undef, undef, undef, 0.02;
        print $client "0\r\n\r\n";
        close $client;
    }
}

###############################################################################
