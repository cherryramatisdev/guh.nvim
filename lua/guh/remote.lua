--- Resolves a directory's git remote into a provider-agnostic repo identity.
---
--- This replaces `gh repo view` as the repo-resolution step, because `gh repo view` cannot
--- resolve a GitLab remote at all (and vice-versa).

local util = require('guh.util')

local M = {}

--- Session cache for `M.sync_provider`.
--- @type 'github'|'gitlab'|nil
local cached_provider

--- Maps a remote host to a provider name.
---
--- Rule (deliberate): any host containing "github" is GitHub; **every other host is GitLab**.
--- That is the only rule which auto-detects self-hosted GitLab instances whose hostname contains
--- neither word (e.g. "git.ifoodcorp.com.br"). GitHub Enterprise users must set
--- `vim.g.guh_provider`.
---
--- @param host string?
--- @return 'github'|'gitlab'
function M.provider_for_host(host)
  local override = vim.g.guh_provider
  if override == 'github' or override == 'gitlab' then
    return override
  end
  return (host or ''):lower():find('github', 1, true) and 'github' or 'gitlab'
end

--- Synchronously resolves the provider of `dir`'s git remote, cached for the session.
---
--- Used before any async resolution has run, so `guh.provider.current()`'s fallback reflects the
--- actual repo instead of a hard-coded guess. One `git remote get-url` per session.
---
--- @param dir? string
--- @return 'github'|'gitlab'|nil
function M.sync_provider(dir)
  if cached_provider then
    return cached_provider
  end
  local r = vim.system({ 'git', 'remote', 'get-url', 'origin' }, { cwd = dir, text = true }):wait()
  local parsed = M.parse_url(r.code == 0 and vim.trim(r.stdout or '') or '')
  if parsed then
    cached_provider = M.provider_for_host(parsed.host)
  end
  return cached_provider
end

--- Extracts the host from a web URL argument, or nil if `arg` isn't a URL.
---
--- Used to pick the provider for an explicitly-named target (e.g.
--- `:Guh https://gitlab.com/g/s/p/-/merge_requests/1`), since the host is otherwise lost by
--- `util.parse_target`.
---
--- @param arg string?
--- @return string?
function M.host_of(arg)
  local h = (arg or ''):match('https?://([^/%s]+)')
  if not h then
    return nil
  end
  return (h:gsub('^[^@]*@', ''):gsub(':%d+$', ''):lower())
end

--- Parses a git remote URL into `{ host, path }`.
---
--- Handles scp-like ("git@host:group/proj.git"), and ssh/http(s)/git URLs, with or without a
--- user, port, and trailing ".git". Returns nil for anything unrecognized (e.g. a local path).
---
--- @param url string?
--- @return { host: string, path: string }?
function M.parse_url(url)
  url = vim.trim(url or '')
  if url == '' then
    return nil
  end
  local host, path
  -- scp-like: [user@]host:path  (no scheme, so check the scheme form first to avoid
  -- matching the "//" of "https://…" as a path).
  if url:find('://') then
    local _, authority, p = url:match('^(%w+)://([^/]+)/(.+)$')
    if authority then
      host = authority:gsub('^[^@]*@', ''):gsub(':%d+$', '') -- Strip "user@" and ":port".
      path = p
    end
  else
    local _, h, p = url:match('^([%w._-]+)@([%w._-]+):(.+)$')
    if h then
      host, path = h, p
    end
  end
  if not host or not path then
    return nil
  end
  path = path:gsub('%.git$', ''):gsub('/+$', '')
  if host == '' or path == '' then
    return nil
  end
  return { host = host:lower(), path = path }
end

--- Resolves the repo for `cwd` (default: Nvim's CWD).
---
--- @param cwd? string Directory to resolve the repo from.
--- @param on_done fun(remote?: { host: string, path: string, provider: 'github'|'gitlab' })
function M.resolve(cwd, on_done)
  local progress = util.new_progress_report('Loading...', 0)
  progress('running')

  local function finish(url)
    local parsed = M.parse_url(url)
    if not parsed then
      progress('failed')
      return on_done(nil)
    end
    parsed.provider = M.provider_for_host(parsed.host)
    -- Remember which backend owns this repo, so `guh.gh` (the shim) resolves the right one for
    -- buffers of this repo even after CWD moves elsewhere.
    local p = require('guh.provider')
    p.register(parsed.path, parsed.host, parsed.provider)
    p.set_default(parsed.provider)
    progress('success')
    on_done(parsed)
  end

  util.system({ 'git', 'remote', 'get-url', 'origin' }, { cwd = cwd }, function(r)
    local url = r.code == 0 and vim.trim(r.stdout or '') or ''
    if url ~= '' then
      return finish(url)
    end
    -- No `origin` remote: fall back to the first configured remote.
    util.system({ 'git', 'config', '--get-regexp', '^remote%..*%.url$' }, { cwd = cwd }, function(r2)
      local first = r2.code == 0 and (r2.stdout or ''):match('^%S+%s+(%S+)') or nil
      finish(first or '')
    end)
  end)
end

return M
