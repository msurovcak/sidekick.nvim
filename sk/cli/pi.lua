---@param cwd string
---@param limit number
---@return sidekick.cli.session.Info[]
local function discover_sessions(cwd, limit)
  -- Pi stores sessions in ~/.pi/agent/sessions/ organized by working directory
  -- Directory name is cwd with / replaced by -
  local session_base = vim.fs.normalize("~/.pi/agent/sessions")
  
  -- Convert cwd to pi's directory format
  -- /home/user/project -> --home-user-project--
  local cwd_part = cwd:gsub("/", "-")
  if cwd_part:match("^%-") then
    cwd_part = cwd_part:sub(2) -- Remove leading dash
  end
  local project_dir = session_base .. "/--" .. cwd_part .. "--"

  local stat = vim.uv.fs_stat(project_dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  -- Collect all .jsonl session files
  local file_info = {}
  local handle = vim.uv.fs_scandir(project_dir)
  if handle then
    while true do
      local name, file_type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if file_type == "file" and name:match("%.jsonl$") then
        local file_path = project_dir .. "/" .. name
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

  -- Sort by mtime (descending) - most recent first
  table.sort(file_info, function(a, b)
    return a.mtime > b.mtime
  end)

  -- Read only up to limit files
  return vim
    .iter(file_info)
    :take(limit)
    :map(function(info)
      -- Try to extract title from session file
      local fd = vim.uv.fs_open(info.path, "r", 438)
      if not fd then
        return nil
      end
      
      local file_stat = vim.uv.fs_fstat(fd)
      if not file_stat then
        vim.uv.fs_close(fd)
        return nil
      end
      
      -- Read up to 16KB to scan for session info and first user message
      local data = vim.uv.fs_read(fd, math.min(file_stat.size, 16384), 0)
      vim.uv.fs_close(fd)

      local title = nil
      local session_id = nil
      
      if data then
        local lines_scanned = 0
        local first_user_text = nil
        
        for line in data:gmatch("([^\n]+)") do
          lines_scanned = lines_scanned + 1
          if lines_scanned > 50 then
            break
          end
          
          local ok, entry = pcall(vim.json.decode, line)
          if ok and entry then
            -- Extract session ID from header
            if entry.type == "session" and not session_id then
              session_id = entry.id
            end
            
            -- Look for session_info with a name
            if entry.type == "session_info" and entry.name then
              title = entry.name
              break
            end
            
            -- Fall back to first user message
            if first_user_text == nil and entry.type == "message" and entry.message then
              if entry.message.role == "user" then
                local content = entry.message.content
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
        end
        
        if not title then
          title = first_user_text
        end
      end

      -- Truncate long titles
      if title and #title > 80 then
        title = title:sub(1, 80) .. "..."
      end
      
      -- Use filename without extension as fallback ID, or session ID
      local id = session_id or info.filename:match("^(.+)%.jsonl$") or info.filename

      return {
        id = id,
        title = title or id,
        updated = info.mtime,
        cli_name = "pi",
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
  cmd = { "pi" },
  is_proc = "\\<pi\\>",
  url = "https://github.com/badlogic/pi-mono",
  resume = { "--session" },
  continue = { "--continue" },
  discover_sessions = discover_sessions,
  native_scroll = false,
}
