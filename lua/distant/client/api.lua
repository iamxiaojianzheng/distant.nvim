local state = require('distant.state')
local utils = require('distant.utils')

local function clean_data(data)
    if type(data) == 'table' then
        local tbl = data
        for key, value in pairs(tbl) do
            tbl[key] = clean_data(value)
        end
        return tbl
    elseif data == vim.NIL then
        return nil
    else
        return data
    end
end

--- @param msg ClientMsg
--- @param info {type:string, data:table<string, string|{type:string, optional:boolean}>}
--- @return ClientMsg
local function msg_validate(msg, info)
    local opts = {
        type = {msg.type, 'string'},
    }

    for key, value in pairs(info.data) do
        local vtype = value
        local optional = false
        if type(vtype) == 'table' then
            vtype = value.type
            optional = value.optional
        end

        opts[key] = {msg[key], vtype, optional}
    end

    -- Validate input types
    vim.validate(opts)

    -- Validate the table msg type is appropriate
    if msg.type ~= info.type then
        error('[INVALID MSG] Expected ' .. info.type .. ' but got ' .. msg.type, 2)
    end

    return msg
end

--- @class ParseResponseOpts
--- @field payload table @The payload to parse
--- @field expected string|string[] @The type expected for the response
--- @field map? fun(payload:table, type:string, stop:fun()|nil):any @A function that takes the data from a matching result
---             and returns a table in the form of {err, data}
--- @field stop? fun() @If called, will stop receiving future events for the origin of a response

--- Creates a table in the form of {err, data} when given a response with
--- a singular payload entry
---
--- @param opts ParseResponseOpts
--- @return table #The arguments to provide to a callback in form of {err, data}
local function parse_response(opts)
    opts = opts or {}
    vim.validate({
        payload={opts.payload, 'table'},
        expected={opts.expected, {'string', 'table'}},
        map={opts.map, 'function', true},
        stop={opts.stop, 'function', true},
    })
    opts.map = opts.map or function(data) return data end

    local payload = opts.payload
    local type = payload.type
    local data = payload.data

    local is_expected = function(t)
        if type(opts.expected) == 'string' then
            return t == opts.expected
        elseif vim.tbl_islist(opts.expected) then
            return vim.tbl_contains(opts.expected, t)
        else
            return false
        end
    end

    local expected = is_expected(type)

    -- If just expecting an ok type, we just return true
    if expected and type == 'ok' then
        return false, opts.map(true, type, opts.stop), opts.stop
    -- For all other expected types, we return the payload data
    elseif expected then
        return false, opts.map(data, type, opts.stop), opts.stop
    -- If we get an error type, return its description if it has one
    elseif type == 'error' and data and data.description then
        return tostring(data.description), opts.stop
    -- Otherwise, if the error is returned but without a description, report it
    elseif type == 'error' and data then
        return 'Error response received without description', opts.stop
    -- Otherwise, if the error is returned but without a payload, report it
    elseif type == 'error' then
        return 'Error response received without data payload', opts.stop
    -- Otherwise, if we got an unexpected type, report it
    else
        return 'Received invalid response of type ' .. type .. ', wanted ' .. vim.inspect(opts.expected), opts.stop
    end
end

--- @alias ApiCallback fun(err:string|nil, res:table|nil)
--- @alias ApiFnReturn string|nil, table|nil
--- @alias AndThenArgs {err:string|nil, data:table|nil, cb:ApiCallback}

--- @class MakeFnParams
--- @field client Client
--- @field type string
--- @field ret_type string|string[]
--- @field map? fun(data:table, type:string, stop:fun()):table #transform data before it is sent back through callback or return
--- @field and_then? fun(args:AndThenArgs) #invoked with callback, giving control to trigger callback explicitly
--- @field req_type? table #if provided, will use `vim.validate` on request client msg data
--- @field res_type? table #if provided, will use `vim.validate` on resposne client msg data
--- @field multi? boolean #if true, will expect multiple messages in response to request

--- Creates a function that when invoked will synchronously or asynchronously
--- perform the underlying operation. If a callback is provided, this is
--- asynchronous and will trigger the callback when finished in the form of
--- `function(err|nil, data|nil)`. If no callback is provided, then this is
--- will be invoked synchronously and return `err|nil, data|nil`
---
--- @param params MakeFnParams
--- @return fun(msgs:OneOrMoreMsgs, opts?:table, cb?:ApiCallback):ApiFnReturn
local function make_fn(params)
    vim.validate({
        client = {params.client, 'table'},
        type = {params.type, 'string'},
        ret_type = {params.ret_type, {'string', 'table'}},
        map = {params.map, 'function', true},
        and_then = {params.and_then, 'function', true},
        req_type = {params.req_type, 'table', true},
        res_type = {params.res_type, 'table', true},
        multi = {params.multi, 'boolean', true},
    })

    --- @param msg OneOrMoreMsgs
    --- @param opts? table
    --- @param cb? ApiCallback
    --- @return ApiFnReturn
    return function(msg, opts, cb)
        -- If we are provided just the msgs and callback (not opts), move
        -- the arguments around to correctly assign cb as callback
        if type(opts) == 'function' and cb == nil then
            cb = opts
            opts = {}
        end

        -- If we are provided a filler value for opts or nothing at all,
        -- ensure that it is an empty table instead
        if not opts then
            opts = {}
        end

        -- If no callback provided, then this is synchronous and we want
        -- to use a oneshot channel so we can block waiting for the result
        local rx
        if not cb then
            cb, rx = utils.oneshot_channel(
                opts.timeout or state.settings.max_timeout,
                opts.interval or state.settings.timeout_interval
            )
        end

        -- @type ClientMsg[]
        local msgs
        if not vim.tbl_islist(msg) then
            msgs = {msg}
        else
            msgs = msg
        end

        -- Ensure that our parameters are actually the right type in case
        -- someone feeds in something weird like a string for opts or a
        -- boolean for the callback
        vim.validate({
            msgs = {msgs, 'table'},
            opts = {opts, 'table'},
            cb = {cb, 'function'},
        })

        if params.req_type then
            for _, m in ipairs(msgs) do
                local status, err = pcall(msg_validate, m, params.req_type)
                if not status then
                    -- Synchronous
                    if rx then
                        return err

                    -- Asynchronous
                    else
                        return cb(err)
                    end
                end
            end
        end

        -- Configure whether or not we are a multi send
        opts = vim.tbl_extend('keep', {multi = params.multi}, opts)

        params.client:send(msgs, opts, function(res, stop)
            local reply = cb
            if params.and_then then
                reply = function(err, data, f)
                    local args = {
                        err = err,
                        data = data,
                        stop = f,
                        cb = cb,
                    }
                    if not args.stop and type(data) == 'function' then
                        args.data = nil
                        args.stop = data
                    end
                    params.and_then(args)
                end
            end

            if params.res_type and res and res.payload and res.payload.data then
                -- @type ClientMsg[]
                local res_payload_data = res.payload.data
                if not vim.tbl_islist(res_payload_data) then
                    msgs = {res_payload_data}
                end


                for _, m in ipairs(res_payload_data) do
                    local status, err = pcall(msg_validate, m, params.res_type)
                    if not status then
                        if stop then
                            stop()
                        end
                        return reply(err)
                    end
                end
            end

            return reply(parse_response({
                payload = clean_data(res),
                expected = params.ret_type,
                map = params.map,
                stop = stop,
            }))
        end)

        -- If we have a receiver, this indicates that we are synchronous
        if rx then
            local err1, err2, result, stop = rx()
            return err1 or err2, result, stop
        end
    end
end

--- @param client Client
--- @return ClientApi
return function(client)
    local api = {
        __state = {
            processes = {},
        }
    }

    --- @type ApiAppendFile
    api.append_file = make_fn({
        client = client,
        type = 'file_append',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            data = 'table',
        }
    })

    --- @type ApiAppendFileText
    api.append_file_text = make_fn({
        client = client,
        type = 'file_append_text',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            text = 'string',
        },
    })

    --- @type ApiCopy
    api.copy = make_fn({
        client = client,
        type = 'copy',
        ret_type = 'ok',
        req_type = {
            src = 'string',
            dst = 'string',
        },
    })

    --- @type ApiCreateDir
    api.create_dir = make_fn({
        client = client,
        type = 'dir_create',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            all = {type = 'boolean', optional = true},
        },
    })

    --- @type ApiExists
    api.exists = make_fn({
        client = client,
        type = 'exists',
        ret_type = 'exists',
        req_type = {
            path = 'string',
        },
        res_type = {
            value = 'boolean',
        },
    })

    --- @type ApiMetadata
    api.metadata = make_fn({
        client = client,
        type = 'metadata',
        ret_type = 'metadata',
        req_type = {
            path = 'string',
            canonicalize = {type = 'boolean', optional = true},
            resolve_file_type = {type = 'boolean', optional = true},
        },
        res_type = {
            canonicalized_path = {type = 'string', optional = true},
            file_type = 'string',
            len = 'number',
            readonly = 'boolean',
            accessed = {type = 'number', optional = true},
            created = {type = 'number', optional = true},
            modified = {type = 'number', optional = true},
            unix = {type = 'table', optional = true},
            windows = {type = 'table', optional = true},
        },
    })

    --- @type ApiReadDir
    api.read_dir = make_fn({
        client = client,
        type = 'dir_read',
        ret_type = 'dir_entries',
        req_type = {
            path = 'string',
            depth = {type = 'number', optional = true},
            absolute = {type = 'boolean', optional = true},
            canonicalize = {type = 'boolean', optional = true},
            include_root = {type = 'boolean', optional = true},
        },
        res_type = {
            entries = 'table',
            errors = 'table',
        },
    })

    --- @type ApiReadFile
    api.read_file = make_fn({
        client = client,
        type = 'file_read',
        ret_type = 'blob',
        req_type = {
            path = 'string',
        },
        res_type = {
            data = 'table',
        },
    })

    --- @type ApiReadFileText
    api.read_file_text = make_fn({
        client = client,
        type = 'file_read_text',
        ret_type = 'text',
        req_type = {
            path = 'string',
        },
        res_type = {
            data = 'string',
        },
    })

    --- @type ApiRemove
    api.remove = make_fn({
        client = client,
        type = 'remove',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            force = {type = 'boolean', optional = true },
        },
    })

    --- @type ApiRename
    api.rename = make_fn({
        client = client,
        type = 'rename',
        ret_type = 'ok',
        req_type = {
            src = 'string',
            dst = 'string',
        },
    })

    --- @type ApiSpawn
    api.spawn = make_fn({
        client = client,
        type = 'proc_spawn',
        ret_type = {'proc_spawned', 'proc_stdout', 'proc_stderr', 'proc_done'},
        req_type = {
            cmd = 'string',
            args = {type = 'table', optional = true},
            persist = {type = 'boolean', optional = true},
            pty = {type = 'table', optional = true},
        },
        multi = true,
        map = function(data, type, stop)
            -- NOTE: This callback will be triggered multiple times for
            --       different proc events; so, we need to handle them
            --       in specialized ways. The callback will only be
            --       triggered once when we first get the proc spawned
            --       event whereas all other events will be mapped to
            --       the created process
            if type == 'proc_spawned' then
                local id = tostring(data.id)
                local write_stdin = make_fn({
                    client = client,
                    type = 'proc_stdin',
                    ret_type = 'ok',
                    req_type = {
                        id = 'number',
                        data = 'table',
                    },
                })
                local kill = make_fn({
                    client = client,
                    type = 'proc_kill',
                    ret_type = 'ok',
                    req_type = {
                        id = 'number',
                    },
                })

                --- Poll some value from the process for changes
                local function poll(check, opts, cb)
                    if type(opts) == 'function' and cb == nil then
                        cb = opts
                        opts = {}
                    end

                    if not opts then
                        opts = {}
                    end

                    local interval = opts.interval or state.settings.timeout_interval
                    local rx
                    if not cb then
                        cb, rx = utils.oneshot_channel(
                            opts.timeout or state.settings.max_timeout,
                           interval
                        )
                    end

                    local timer = vim.loop.new_timer()
                    timer:start(0, interval, function()
                        local value = check()
                        if value then
                            timer:close()
                            cb(false, value)
                        end
                    end)

                    if rx then
                        local err1, err2, result = rx()
                        return err1 or err2, result
                    end
                end

                local proc = {
                    __state = {
                        stdout = {},
                        stderr = {},
                        status = nil,
                        exit_code = nil,
                    },

                    id = id,
                    stop = stop,

                    is_active = function()
                        return not (not api.__state.processes[id])
                    end,

                    write_stdin = function(d, opts, cb)
                        return write_stdin({
                            id = id,
                            data = d,
                        }, opts, cb)
                    end,

                    read_stdout = function(opts, cb)
                        return poll(function()
                            local proc = api.__state.processes[id]
                            local stdout = proc.__state.stdout
                            if not vim.tbl_isempty(stdout) then
                                proc.__state.stdout = {}
                                return stdout
                            end
                        end, opts, cb)
                    end,

                    read_stderr = function(opts, cb)
                        return poll(function()
                            local proc = api.__state.processes[id]
                            local stderr = proc.__state.stderr
                            if not vim.tbl_isempty(stderr) then
                                proc.__state.stderr = {}
                                return stderr
                            end
                        end, opts, cb)
                    end,

                    is_done = function()
                        local proc = api.__state.processes[id]
                        return proc and proc.__state.status ~= nil
                    end,

                    wait = function(opts, cb)
                        return poll(function()
                            local proc = api.__state.processes[id]
                            if proc.__state.status ~= nil then
                                api.__state.processes[id] = nil
                                return proc
                            end
                        end, opts, cb)
                    end,

                    kill = function(opts, cb)
                        return kill({id = id}, opts, cb)
                    end,
                }

                api.__state.processes[id] = proc
                return {
                    type = type,
                    proc = proc,
                }
            else
                return {
                    type = type,
                    data = data,
                }
            end
        end,
        and_then = function(args)
            local err = args.err
            local data = args.data
            local stop = args.stop
            local cb = args.cb

            if data.type == 'proc_spawned' then
                return cb(err, data.proc)
            elseif data.type == 'proc_done' then
                local id = tostring(data.id)
                local p = api.__state.processes[id]
                p.__state.status = data.status
                p.__state.exit_code = data.code
                stop()
            elseif data.type == 'proc_stdout' then
                local id = tostring(data.id)
                local p = api.__state.processes[id]
                vim.list_extend(p.__state.stdout, data.data)
            elseif data.type == 'proc_stderr' then
                local id = tostring(data.id)
                local p = api.__state.processes[id]
                vim.list_extend(p.__state.stderr, data.data)
            end
        end,
    })

    --- @type ApiSpawnWait
    api.spawn_wait = function(msgs, opts, cb)
        return api.spawn(msgs, opts, function(err, proc)
            if err then
                return cb(err)
            end

            return proc:output(function(err2, output)
                if err2 then
                    return cb(err2)
                end

                return cb(false, output)
            end)
        end)
    end

    --- @type ApiSystemInfo
    api.system_info = make_fn({
        client = client,
        type = 'system_info',
        ret_type = 'system_info',
        res_type = {
            family = 'string',
            os = 'string',
            arch = 'string',
            current_dir = 'string',
            main_separator = 'string',
        },
    })

    --- @type ApiWatch
    api.watch = make_fn({
        client = client,
        type = 'watch',
        ret_type = {'ok', 'changed'},
        req_type = {
            path = 'string',
            recursive = {type = 'boolean', optional = true},
            only = {type = 'table', optional = true},
            except = {type = 'table', optional = true},
        },
        multi = true,
        map = function(data, type, stop)
            return {
                data = data,
                type = type,
                stop = stop,
            }
        end,
        and_then = function(args)
            local err = args.err
            local data = args.data
            local cb = args.cb

            if err then
                return cb(err)
            end

            -- If we get ok, that means the watch succeeded
            -- and we want to store the stop function
            if data.type == 'ok' then

            -- Otherwise, we got a changed event and want
            -- to pass that along to our callback
            else

            end
        end,
    })

    --- @type ApiWriteFile
    api.write_file = make_fn({
        client = client,
        type = 'file_write',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            data = 'table',
        },
    })

    --- @type ApiWriteFileText
    api.write_file_text = make_fn({
        client = client,
        type = 'file_write_text',
        ret_type = 'ok',
        req_type = {
            path = 'string',
            text = 'string',
        },
    })

    --- @type ApiUnwatch
    api.unwatch = make_fn({
        client = client,
        type = 'unwatch',
        ret_type = 'ok',
        req_type = {
            path = 'string',
        },
        and_then = function()
            -- TODO: Delete watcher
        end,
    })

    return api
end
