local log    = require('distant-core').log
local plugin = require('distant')

local mapper = require('distant.editor.open.mapper')

local M      = {}

--- @class distant.editor.open.ConfigureOpts
--- @field bufnr number # number associated with the buffer
--- @field name string #name of the buffer (e.g. distant://path/to/file.txt)
--- @field canonicalized_path string #primary path (e.g. path/to/file.txt)
--- @field raw_path string #raw input path, which could be an alt path
--- @field is_dir boolean #true if buffer represents a directory
--- @field is_file boolean #true if buffer represents a file
--- @field missing boolean
--- @field timestamp? integer
--- @field no_focus? boolean #true if focus of the window should not be set to the buffer
--- @field client_id? distant.core.manager.ConnectionId # id of the client to use
--- @field winnr? number #window number to use

--- @param opts distant.editor.open.ConfigureOpts
function M.configure(opts)
    log.fmt_trace('configurator.configure(%s)', opts)

    local bufnr = opts.bufnr
    local winnr = opts.winnr or 0
    local bufname = opts.name

    --- NOTE: We have to capture the old buffer name and then check
    ---       if setting a new name copies the old buffer name to be
    ---       unlisted. If so, we delete it.
    --- Issue: https://github.com/neovim/neovim/issues/20059
    ---
    --- @diagnostic disable-next-line:redefined-local
    local function set_bufname(bufnr, bufname)
        local old_bufname = vim.api.nvim_buf_get_name(bufnr)
        if old_bufname == bufname then
            log.fmt_debug('Buffer already had this name')
            return
        end

        -- Set the buffer name to include a schema, which will trigger our
        -- autocmd for writing to the remote destination in the situation
        -- where we are editing a file
        vim.api.nvim_buf_set_name(bufnr, bufname)

        -- Look for any buffer that is NOT this one that contains the same
        -- name prior to us setting the new name
        --
        -- If we find a match, this is a bug in neovim (?) and we delete it
        --
        --- @diagnostic disable-next-line:redefined-local
        for _, nr in ipairs(vim.api.nvim_list_bufs()) do
            if bufnr ~= nr then
                local name = vim.api.nvim_buf_get_name(nr)
                if name == old_bufname then
                    vim.api.nvim_buf_delete(nr, { force = true })
                end
            end
        end
    end

    --
    -- Configure buffer options for directory & file
    --

    -- If a directory, we want to mark as such and prevent modifying;
    -- otherwise, in all other cases we treat this as a remote file
    if opts.is_dir then
        log.fmt_debug('Setting buffer %s as a directory', bufnr)

        -- Mark the buftype as nofile and not modifiable as you cannot
        -- modify it or write it; also explicitly set a custom filetype
        vim.bo[bufnr].filetype = 'distant-dir'
        vim.bo[bufnr].buftype = 'nofile'
        vim.bo[bufnr].modifiable = false

        -- If enabled, apply our directory keymappings
        local keymap = plugin.settings.keymap.dir
        if keymap.enabled then
            local nav = require('distant.nav')
            mapper.apply_mappings(bufnr, {
                [keymap.copy]     = nav.actions.copy,
                [keymap.edit]     = nav.actions.edit,
                [keymap.tabedit]  = nav.actions.tabedit,
                [keymap.metadata] = nav.actions.metadata,
                [keymap.newdir]   = nav.actions.mkdir,
                [keymap.newfile]  = nav.actions.newfile,
                [keymap.rename]   = nav.actions.rename,
                [keymap.remove]   = nav.actions.remove,
                [keymap.up]       = nav.actions.up,
            })
        end
    else
        log.fmt_debug('Setting buffer %s as a file', bufnr)

        -- Mark the buftype as acwrite as you can still write to it, but we
        -- control where it is going
        vim.bo[bufnr].buftype = 'acwrite'

        -- If enabled, apply our file keymappings
        local keymap = plugin.settings.keymap.file
        if keymap.enabled then
            local nav = require('distant.nav')
            mapper.apply_mappings(bufnr, {
                [keymap.up] = nav.actions.up,
            })
        end
    end

    --
    -- Add stateful information to the buffer, helping keep track of it
    --

    log.fmt_debug('Storing variables for buffer %s', bufnr)
    local buffer = plugin.buf(bufnr)

    -- Ensure that we have a client configured
    buffer.set_client_id(
        opts.client_id or
        assert(
            plugin:active_client_id(),
            ('Buffer %s opened without a distant client'):format(bufnr)
        )
    )

    -- Set our path information
    buffer.set_path(opts.canonicalized_path)
    buffer.set_type(opts.is_dir and 'dir' or 'file')

    -- Add the raw path as an alternative path that can be used
    -- to look up this buffer
    buffer.add_alt_path(opts.raw_path, { dedup = true })

    -- Set our modification time
    if opts.timestamp then
        buffer.set_mtime(opts.timestamp)
    end

    -- Set our watched status to false only if not set yet
    if buffer.watched() == nil then
        buffer.set_watched(false)
    end

    -- Ensure that the data has been stored
    log.fmt_debug('Buffer %s stored variables: %s', bufnr, buffer.assert_data())

    -- Update the buffer name to proper reflect
    -- NOTE: This MUST be done after we set our variables, otherwise
    --       this will trigger entering a buffer and result
    --       in trying to load the buffer that is already loaded
    --       without being properly initialized
    log.fmt_debug('Setting buffer %s name to %s', bufnr, bufname)
    set_bufname(bufnr, bufname)

    -- Display the buffer in the specified window, defaulting to current
    if not opts.no_focus then
        if winnr == -1 then
            -- TODO: At time of implementation there does not seem to be a lua API to create a new tabpage
            vim.api.nvim_command('tabedit')
            winnr = 0
        end
        vim.api.nvim_win_set_buf(winnr, bufnr)
    end

    --
    -- Configure extra file details & LSP clients
    --

    if opts.is_file or opts.missing then
        -- Set our filetype to whatever the contents actually are (or file extension is)
        local success, filetype = pcall(vim.filetype.match, { buf = bufnr })
        if success and filetype then
            log.fmt_debug('Setting buffer %s filetype to %s', bufnr, filetype)
            vim.bo[bufnr].filetype = filetype
        end

        -- Launch any associated LSP clients
        local client = assert(
            plugin:client(opts.client_id),
            'No connection has been established!'
        )
        client:connect_lsp_clients({
            bufnr = bufnr,
            path = buffer.assert_path(),
            scheme = buffer.name.prefix(),
            settings = plugin:server_settings_for_client().lsp,
        })
    end

    -- Watch the buffer to detect changes (only applies to files)
    --
    -- TODO: We need to support getting the version of the server that includes
    --       the capabilities and be able to look them up here. The reason for
    --       that is some implementations such as ssh do not support file watching
    --       and the act of trying to watch will return an error. So we want to know
    --       if a server supports the watch capability and skip this (even if enabled)
    --       when it does not.
    if plugin.settings.buffer.watch.enabled then
        plugin.editor.watch({ buf = bufnr })
    end
end

return M
