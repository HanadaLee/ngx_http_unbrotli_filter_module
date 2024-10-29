# Name
ngx_http_unbrotli_filter_module is a filter that decompresses responses with “Content-Encoding: brotli” for clients that do not support “brotli” encoding method. The module will be useful when it is desirable to store data compressed to save space and reduce I/O costs.

# Table of Content

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Installation](#installation)
* [Directives](#directives)
  * [unbrotli](#unbrotli)
  * [unbrotli_force](#unbrotli_force)
  * [unbrotli_buffers](#unbrotli_buffers)
* [Author](#author)
* [License](#license)

# Status

This Nginx module is currently considered experimental.

# Synopsis

```nginx
server {
    listen 127.0.0.1:8080;
    server_name localhost;

    location / {
        # enable brotli decompression for clients that do not support brotli compression
        unbrotli on;

        proxy_pass http://foo.com;
    }
}
```

# Installation

To use theses modules, configure your nginx branch with `--add-module=/path/to/ngx_http_unbrotli_filter_module`. Additionally, you need to pre-build the brotli decompression library.

# Directives

## unbrotli

**Syntax:** *unbrotli on | off;*

**Default:** *unbrotli off;*

**Context:** *http, server, location*

Enables or disables decompression of brotli compressed responses for clients that lack brotli support.

## unbrotli_force

**Syntax:** *unbrotli_force on | off;*

**Default:** *unbrotli_force off;*

**Context:** *http, server, location*

Enables or disables forced brotli decompression of upstream content.

## unbrotli_buffers

**Syntax:** *unbrotli_buffers number size;*

**Default:** *unbrotli_buffers 32 4k | 16 8k;*

**Context:** *http, server, location*

Sets the number and size of buffers used to decompress a response. By default, the buffer size is equal to one memory page. This is either 4K or 8K, depending on a platform.

# Author

[clyfish](https://github.com/clyfish)

This module is forked from [ngx_unbrotli](https://github.com/clyfish/ngx_unbrotli)