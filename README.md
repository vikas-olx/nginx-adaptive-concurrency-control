# nginx-adaptive-concurrency-control
NGINX Lua plugin for adaptive concurrency control used to handle overload in services

# Introduction
Chameleon is an NGINX Lua plugin for adaptive concurrency control in services. NGINX, with Chameleon plugin installed, is deployed as a reverse proxy in front of the service. Chameleon then limits the concurrency (No. of in-flight requests to the services) to avoid overload and it adaptively adjusts this limit based on the service response times.  

I've written a series of blog posts on adaptive concurrency control and what problems does Chameleon solve.

[https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-1.html](https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-1.html)

[https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-2.html](https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-2.html)

[https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-3.html](https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-3.html)

[https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-4.html](https://www.resilientsystems.io/2020/05/15/adaptive-concurrency-control-algorithms-part-4.html)

# How To Use

## Install OpenResty

First, you need to install the [NGINX Lua Module](https://github.com/openresty/lua-nginx-module) to enable Lua support in NGINX. One simple way is to just use [OpenResty](https://openresty.org/en/installation.html) instead of plain NGINX. OpenResty is basically NGINX with the power of Lua modules. It comes pre-packaged with a lot of [Lua Modules](https://openresty.org/en/components.html) and more can be added via [OPM](https://opm.openresty.org/).

## Use Chameleon

Here's an example of how you can use Chameleon with OpenResty.

* Install OpenResty
* Create a directoy (say `hello`)
* Create directories `hello/conf` and `hello/luamodules`
* Copy Lua files from this repo (`chameleon.lua`, `aimd.lua`, `gradient.lua` and `windowed_latency.lua`) to `hello/luamodules`
* Chameleon has a dependency on [lua-resty-timer](https://github.com/Kong/lua-resty-timer) module. You can simply copy `/lib/resty/timer.lua` file to `hello/luamodules`
* Create nginx.conf file in `hello/conf` directory with the following content:
```java
worker_processes  4;
error_log logs/error.log;
events {
    worker_connections 1024;
}
http {
    lua_package_path "/path/to/hello/luamodules/?.lua;;";

    lua_shared_dict chameleon_shm 10m;

    init_worker_by_lua_block {

        props = {
            initial_concurrency_limit = 30,
            min_concurrency_limit = 10,
            max_concurrency_limit = 50,
            limit_shm = "chameleon_shm",
            latency_props = {
                window_size = 1, 
                min_requests = 2,
                metric = "percentile",
                percentile_val = 90
            },
            algo_props = {
                algo = "Gradient",
                long_window = 20
            }
        }

        chameleon_shm_lib = require "chameleon_shm"
        chameleon, err = chameleon_lib.new(props)  
        chameleon:start()
    }

    server {
        listen 8081;
        location / {

            access_by_lua_block {
            
                local allowed, err = chameleon:incoming()
                if not allowed then
                    return ngx.exit(503)
                end

                local ctx = ngx.ctx
                ctx.allowed = true
            }

            proxy_pass http://localhost:8080/;

            log_by_lua_block {
                local ctx = ngx.ctx
                local allowed = ctx.allowed

                if allowed then
                    local latency = math.floor(tonumber(ngx.var.request_time) * 1000)
                    local conn, err = chameleon:leaving(latency)
                    if not conn then
                        ngx.log(ngx.ERR,
                                "failed to record the connection leaving ",
                                "request: ", err)
                        return
                    end
                end    
            }
        }
    }
}
```

Let's go through the important sections in this conf:

### Lua Package Path
This is the path to Lua package files. In our case, it should point to `hello/luamodules`

### Shared Memory
Chameleon needs to store some data in a shared dictionary to be accessed by all NGINX workers. Here, we specify the shared dictionary's name and size (10 MB).

### init_worker_by_lua_block
The code in this block is executed when each NGINX worker starts up. This is where we initialize Chameleon. 

### Props
Props dictionary contains all the configuration for Chameleon. 

* #### initial_concurrency_limit
    Concurrency limit to start with. If the number of in-flight requests to the service exceed this number, Chameleon will start throttling.

* #### min_concurrency_limit
    Concurrency limit can never go below this number.  

* #### max_concurrency_limit
    Concurrency limit can never go beyond this number.

* #### limit_shm
    Name of the shared dictionary.

* #### latency_props
    Configuration to compute request latency 
    ##### window_size
    Time window to compute latency. The latency of all the requests in this time window will be used to compute windowed latency. The value is in seconds. However, we can specify fractional values e.g. 0.01 for 10 ms windows.
    ##### min_requests
    Minimum number of requests that should come in the window for us to be able to compute latency.
    ##### metric
    Metric used to compute latency. It can either be `average` or `percentile`
    ##### percentile_val
    If the metric is `percentile`, we need to specify a percentile value e.g. 99 or 95 or 90. It must be greater than 50.

* #### algo_props
    Configuration for concurrency adjustment algo
    ##### algo
    It can be either `AIMD` or `Gradient`
    ##### timeout
    [_For AIMD algo only_ & _Mandatory_] The latency that must be considered high. If windowed latency is greater than this, comncurrency limit must be decreased.
    ##### backoff_factor
    [_For AIMD algo only_ & _Optional_] The multiplicative factor by which we should decrease concurrency limit. Must be >= 0.5 and < 1. Default is 0.9.
    ##### long_window
    [_For Gradient algo only_ & _Mandatory_] The length og the long window.

### Instantiate & Start Chameleon
We then instantiate Chameleon using the props and start it. Starting Chameleon also kicks off a timer which triggers every `window_size` seconds to adjust concurrency based on the algo and windowed latency.

### access_by_lua_block 
This is triggered for each request, before it is sent to the upstream. Here we add the request to Chameleon. Chameleon maintains the current number of in-flight requests (IFR). This the current IFR already equals the current concurrency limit, this request is throttled, else it is allowed and IFR is incremented. 

### log_by_lua_block 
This is triggered for each request, after the upstream has responsed. Here we register the request leaving i.e. we decrement IFR and add request latency to the window. 

