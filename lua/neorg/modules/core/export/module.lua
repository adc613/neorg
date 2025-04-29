--[[
    file: Exporting-Files
    title: Convert Neorg Files to other Filetypes with `core.export`
    summary: Exports Neorg documents into any other supported filetype.
    ---
When sending files to people not invested in Neorg it's nice to be able to use a format
that *they* use. The `core.export` module is a backend module providing functionality
to write your own exporter for any given filetype.

All export functionality is provided by the `:Neorg export` command.

To export the currently opened buffer to another file format, you should use the `:Neorg export to-file` command.
The command takes the following arguments:
- `path` - the path to export to. Examples are: `my-file.md`, `~/output.md`.
  If the second argument is not provided Neorg will try to infer the filetype to convert to through
  the file extension.
- `filetype` (optional) - the filetype to export to. Useful if you want to use a non-standard extension, or
  if the filetype you're using cannot be inferred automatically. Note that this filetype *must* be a filetype
  that Neovim itself provides and/or understands, i.e. `md` or `markd` is not a valid filetype, however `markdown` is.

Neorg also supports exporting a directory of files: this is where the `:Neorg export directory` command comes into play.
It takes 3 arguments:
- `directory` - the directory to export
- `filetype` - the filetype to export to
- `output-dir` (optional) - a custom output directory to use. If not provided will fall back to `config.public.export_dir`
  (see [configuration](#configuration)).

And if you just want to export a snippet from a single document, you can use `:Neorg export
to-clipboard <filetype>`. Filetype is required, at the time of writing the only option is "markdown".
This copies the range given to the command to the `+` register.
--]]

local neorg = require("neorg.core")
local lib, log, modules, utils = neorg.lib, neorg.log, neorg.modules, neorg.utils
local module = modules.create("core.export")

module.setup = function()
    return {
        success = true,
        requires = {
            "core.integrations.treesitter",
        },
    }
end

---@type core.integrations.treesitter
local ts

module.load = function()
    ts = module.required["core.integrations.treesitter"]

    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            export = {
                args = 1,
                condition = "norg",

                subcommands = {
                    ["to-file"] = {
                        min_args = 1,
                        max_args = 2,
                        name = "export.to-file",
                    },
                    ["directory"] = {
                        min_args = 2,
                        max_args = 3,
                        name = "export.directory",
                    },
                    ["to-clipboard"] = {
                        args = 1,
                        name = "export.to-clipboard",
                    },
                },
            },
        })
    end)
end

module.config.public = {
    -- The directory to export to when running `:Neorg export directory`.
    -- The string can be formatted with the special keys: `<export-dir>` and `<language>`.
    export_dir = "<export-dir>/<language>-export",
}

---@class core.export
module.public = {
    --- Returns a module that can handle conversion from `.norg` to the target filetype
    ---@param ftype string #The filetype to export to
    ---@return table?,table? #The export module and its configuration, else nil
    get_converter = function(ftype)
        if not modules.is_module_loaded("core.export." .. ftype) then
            if not modules.load_module("core.export." .. ftype) then
                return
            end
        end

        return modules.get_module("core.export." .. ftype), modules.get_module_config("core.export." .. ftype)
    end,

        -- Every converter can also come with a `cleanup` function that performs some final tweaks to the output string
        return converter.export.cleanup and converter.export.cleanup(output, state) or output
    end,
}

module.private = {
    ---get the converter for the given filetype
    ---@param filetype string
    ---@return table?, table?
    get_converter_checked = function(filetype)
        local converter, converter_config = module.public.get_converter(filetype)

        if not converter or not converter_config then
            log.error("Unable to export file - did not find exporter for filetype '" .. filetype .. "'.")
            return
        end

        -- Each converter must have a `extension` field in its public config
        -- This is done to do a backwards lookup, e.g. `markdown` uses the `.md` file extension.
        if not converter_config.extension then
            log.error(
                "Unable to export file - exporter for filetype '"
                    .. filetype
                    .. "' did not return a preferred extension. The exporter is unable to infer extensions."
            )
            return
        end

        return converter, converter_config
    end,
}

---@param event neorg.event
module.on_event = function(event)
    if event.type == "core.neorgcmd.events.export.to-file" then
        -- Syntax: Neorg export to-file file.extension forced-filetype?
        -- Example: Neorg export to-file my-custom-file markdown

        local filepath = vim.fn.expand(event.content[1])
        local filetype = event.content[2] or vim.filetype.match({ filename = filepath })
        local exported = module.public.export(event.buffer, filetype)

        vim.loop.fs_open(filepath, "w", 438, function(err, fd)
            assert(not err, lib.lazy_string_concat("Failed to open file '", filepath, "' for export: ", err))
            assert(fd)

            vim.loop.fs_write(fd, exported, 0, function(werr)
                assert(not werr, lib.lazy_string_concat("Failed to write to file '", filepath, "' for export: ", werr))
            end)

            vim.schedule(lib.wrap(utils.notify, "Successfully exported 1 file!"))
        end)
    elseif event.type == "core.neorgcmd.events.export.to-clipboard" then
        -- Syntax: Neorg export to-clipboard filetype
        -- Example: Neorg export to-clipboard markdown

        local filetype = event.content[1]
        local data = event.content.data
        local exported = module.public.export_range(event.buffer, data.line1, data.line2, filetype)

        vim.fn.setreg("+", exported, "l")
    elseif event.type == "core.neorgcmd.events.export.directory" then
        local path = event.content[3] and vim.fn.expand(event.content[3])
            or module.config.public.export_dir
                :gsub("<language>", event.content[2])
                :gsub("<export%-dir>", event.content[1])
        vim.fn.mkdir(path, "p")

        -- The old value of `eventignore` is stored here. This is done because the eventignore
        -- value is set to ignore BufEnter events before loading all the Neorg buffers, as they can mistakenly
        -- activate the concealer, which not only slows down performance notably but also causes errors.
        local old_event_ignore = table.concat(vim.opt.eventignore:get(), ",")

        vim.loop.fs_scandir(event.content[1], function(err, handle)
            assert(not err, lib.lazy_string_concat("Failed to scan directory '", event.content[1], "': ", err))
            assert(handle)

            local file_counter, parsed_counter = 0, 0

            while true do
                local name, type = vim.loop.fs_scandir_next(handle)

                if not name then
                    break
                end

                if type == "file" and vim.endswith(name, ".norg") then
                    file_counter = file_counter + 1

                    local function check_counters()
                        parsed_counter = parsed_counter + 1

                        if parsed_counter >= file_counter then
                            vim.schedule(
                                lib.wrap(utils.notify, string.format("Successfully exported %d files!", file_counter))
                            )
                        end
                    end

                    vim.schedule(function()
                        local filepath = vim.fn.expand(event.content[1]) .. "/" .. name

                        vim.opt.eventignore = "BufEnter"

                        local buffer = assert(vim.fn.bufadd(filepath))
                        vim.fn.bufload(buffer)

                        vim.opt.eventignore = old_event_ignore

                        local exported, extension = module.public.export(buffer, event.content[2])

                        vim.api.nvim_buf_delete(buffer, { force = true })

                        if not exported then
                            check_counters()
                            return
                        end

                        local write_path = path .. "/" .. name:gsub("%.%a+$", "." .. extension)

                        vim.loop.fs_open(write_path, "w+", 438, function(fs_err, fd)
                            assert(
                                not fs_err,
                                lib.lazy_string_concat("Failed to open file '", write_path, "' for export: ", fs_err)
                            )
                            assert(fd)

                            vim.loop.fs_write(fd, exported, 0, function(werr)
                                assert(
                                    not werr,
                                    lib.lazy_string_concat(
                                        "Failed to write to file '",
                                        write_path,
                                        "' for export: ",
                                        werr
                                    )
                                )

                                check_counters()
                            end)
                        end)
                    end)
                end
            end
        end)
    end

    vim.api.nvim_exec_autocmds("User", {
        pattern = "NeorgExportComplete",
    })
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["export.to-file"] = true,
        ["export.to-clipboard"] = true,
        ["export.directory"] = true,
    },
}

return module
