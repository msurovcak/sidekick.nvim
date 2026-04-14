---@param cwd string
---@return string
local function cwd_to_project(cwd)
  -- Convert /home/user/ghq/github.com/owner/repo -> -home-user-ghq-github-com-owner-repo
  -- Claude replaces all non-alphanumeric characters (except -) with -
  -- Example: test-path_with.symbols+chars@123[test](foo)~bar,baz%qux{}
  --       -> -test-path-with-symbols-chars-123-test--foo--bar-baz-qux--
  return "-" .. cwd:gsub("^/", ""):gsub("[^%w%-]", "-")
end

---@param cwd string
---@param limit number
---@return sidekick.cli.session.Info[]
local function discover_sessions(cwd, limit)
  local project = cwd_to_project(cwd)
  local session_dir = vim.fs.normalize("~/.claude/projects/" .. project)

  local stat = vim.uv.fs_stat(session_dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  -- Find all .jsonl files (exclude agent-* files) and get mtime
  local handle = vim.uv.fs_scandir(session_dir)
  local file_info = {}
  if handle then
    while true do
      local name, type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "file" and name:match("%.jsonl$") and not name:match("^agent%-") then
        local file_path = session_dir .. "/" .. name
        local file_stat = vim.uv.fs_stat(file_path)
        if file_stat then
          table.insert(file_info, {
            path = file_path,
            filename = name,
            mtime = file_stat.mtime.sec,
          })
        end
      end
    end
  end

  -- Sort by mtime (descending)
  table.sort(file_info, function(a, b)
    return a.mtime > b.mtime
  end)

  -- Read only up to limit files
  return vim
    .iter(file_info)
    :take(limit)
    :map(function(info)
      local session_id = info.filename:match("^(.+)%.jsonl$")
      if not session_id then
        return nil
      end

      local fd = vim.uv.fs_open(info.path, "r", 438)
      if not fd then
        return nil
      end
      local file_stat = vim.uv.fs_fstat(fd)
      if not file_stat then
        vim.uv.fs_close(fd)
        return nil
      end
      -- Read up to 8KB to scan the first ~20 lines for a summary or user message
      local data = vim.uv.fs_read(fd, math.min(file_stat.size, 8192), 0)
      vim.uv.fs_close(fd)

      local title = nil
      if data then
        local lines_scanned = 0
        local first_user_text = nil
        for line in data:gmatch("([^\n]+)") do
          lines_scanned = lines_scanned + 1
          if lines_scanned > 20 then
            break
          end
          local ok, meta = pcall(vim.json.decode, line)
          if ok and meta then
            if meta.type == "summary" and meta.summary then
              -- Prefer explicit summary lines (forward-compatible)
              title = meta.summary
              break
            elseif first_user_text == nil and meta.type == "user" then
              -- Fall back to first user message text
              local content = meta.message and meta.message.content
              if type(content) == "string" then
                first_user_text = content
              elseif type(content) == "table" then
                for _, part in ipairs(content) do
                  if type(part) == "table" and part.type == "text" and part.text then
                    first_user_text = part.text
                    break
                  end
                end
              end
            end
          end
        end
        if not title then
          title = first_user_text
        end
      end

      -- Truncate long titles
      if title and #title > 80 then
        title = title:sub(1, 80) .. "..."
      end

      return {
        id = session_id,
        title = title or session_id,
        updated = info.mtime,
        cli_name = "claude",
        cwd = cwd,
      }
    end)
    :filter(function(session)
      return session ~= nil
    end)
    :totable()
end

---@type sidekick.cli.Config
return {
  cmd = { "claude" },
  is_proc = "\\<claude\\>",
  url = "https://github.com/anthropics/claude-code",
  resume = { "--resume" },
  continue = { "--continue" },
  discover_sessions = discover_sessions,
  format = function(text)
    local Text = require("sidekick.text")

    Text.transform(text, function(str)
      return str:find("[^%w/_%.%-]") and ('"' .. str .. '"') or str
    end, "SidekickLocFile")

    local ret = Text.to_string(text)

    -- transform line ranges to a format that Claude understands
    ret = ret:gsub("@([^@]-) :L(%d+)%-L(%d+)", "@%1#L%2-%3")

    return ret
  end,
}
