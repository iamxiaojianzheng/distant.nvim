local plugin = require('distant')
local utils = require('distant.commands.utils')

local parent_path = require('distant-core.utils').parent_path

--- DistantOpen path [opt1=... opt2=...]
--- @param cmd NvimCommand
local function command(cmd)
    local input = utils.parse_args(cmd.args)
    utils.paths_to_number(input.opts, {
        'bufnr',
        'winnr',
        'line',
        'col',
        'client_id',
        'timeout',
        'interval',
    })
    utils.paths_to_bool(input.opts, {
        'reload',
        'no_focus',
    })
    local opts = input.opts

    local path = input.args[1]

    -- If given nothing as the path, we want to replace it with current directory
    --
    -- The '.' signifies the current directory both on Unix and Windows
    if path == nil or vim.trim(path):len() == 0 then
        path = '.'
    end

    -- Update our options with the path
    opts.path = path

    -- TODO: Support bang! to force-reload a file, and
    --       by default not reload it if there are
    --       unsaved changes
    plugin.editor.open(opts)
end

local function completion(ArgLead,_,_)
    local seperator = require('distant-core.utils').seperator()

    -- Helper: Get the last component of a path
    local function last_component(path)
        local parts = vim.split(path, seperator)
        return parts[#parts]
    end

    local path = ArgLead
    if path == nil or path == '' then
        path = "."
    end

    local component
    if not vim.endswith(path, seperator) and path ~= "." then
        component = last_component(path)
        path = parent_path(path)
    end

    local err, payload = plugin.api().read_dir({
        path = path,
        depth = 1,
        absolute = true,
        canonicalize = true,
    })

    assert(not err, err)
    assert(payload)

    local results = {}

    for _, entry in ipairs(payload.entries) do
        if component == nil or string.match(entry.path, component) then
            local ending_sep = ""
            if entry.file_type == 'dir' then
                ending_sep = seperator
            end
            table.insert(results, entry.path .. ending_sep)
        end
    end

    return results
end

--- @type DistantCommand
local COMMAND = {
    name        = 'DistantOpen',
    description = 'Open a file or directory on the remote machine',
    command     = command,
    bang        = true,
    nargs       = '*',
    complete    = completion,
}
return COMMAND
