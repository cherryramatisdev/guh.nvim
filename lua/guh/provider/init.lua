--- Provider registry and resolution.
---
--- `guh.gh` is a shim that forwards every access to the *active* provider, so the render/UI layer
--- (`guh.pr`, `guh.comments`, `guh.state`, `plugin/guh.lua`) stays provider-agnostic.

local M = {}

--- Lazily-loaded provider backends, keyed by name.
local loaders = {
  github = function()
    return require('guh.provider.github')
  end,
  gitlab = function()
    return require('guh.provider.gitlab')
  end,
}

--- The CLI binary each provider shells out to. Used by `util.system`'s passive rate-limit hook,
--- which must not go through `current()` (that reads `vim.b`, illegal in a fast event context).
local binaries = { github = 'gh', gitlab = 'glab' }

--- repo path ("owner/name", or "group/subgroup/project" for GitLab) → provider/host.
--- @type table<string, { provider: 'github'|'gitlab', host: string? }>
local registry = {}

--- @type table<string, table>
local loaded = {}

--- Provider for resolutions that aren't tied to a buffer (updated by `guh.remote.resolve`).
--- @type 'github'|'gitlab'
M.default_provider = 'github'

--- Gets a provider module by name (loaded once, then cached).
---
--- @param name 'github'|'gitlab'
--- @return table
function M.get(name)
  if not loaded[name] then
    local ok, mod = pcall(loaders[name])
    if not ok then
      error(('guh: provider %q unavailable: %s'):format(name, mod), 0)
    end
    loaded[name] = mod
  end
  return loaded[name]
end

--- Records which provider/host a repo path belongs to, so `current()` can resolve the right
--- backend for the buffer being acted on.
---
--- @param repo string Project path.
--- @param host? string Remote host (e.g. "git.ifoodcorp.com.br").
--- @param provider? 'github'|'gitlab' Defaults to resolving `host` via `guh.remote`.
function M.register(repo, host, provider)
  if not repo or (not host and not provider) then
    return -- Unknown host (e.g. a bare slug names no host): leave it to the default provider.
  end
  registry[repo] = {
    provider = provider or require('guh.remote').provider_for_host(host),
    host = host,
  }
end

--- @param repo string
--- @return { provider: 'github'|'gitlab', host: string? }?
function M.registered(repo)
  return repo and registry[repo] or nil
end

--- Sets the fallback provider (used when the current buffer has no registered repo).
--- @param name 'github'|'gitlab'
function M.set_default(name)
  M.default_provider = name
end

--- Provider implied by a repo path alone.
---
--- GitHub project slugs are always exactly two segments ("owner/name"); GitLab projects may be
--- nested ("group/subgroup/project"). So a 3+ segment path can only be GitLab.
---
--- @param repo string
--- @return 'gitlab'|nil
local function provider_for_path(repo)
  return select(2, repo:gsub('/', '/')) >= 2 and 'gitlab' or nil
end

--- Name of the provider for the current context.
---
--- 1. `vim.g.guh_provider` override, when set.
--- 2. The current buffer's `b:guh.repo`, if it was registered this session. Authoritative: the
---    host was known when the repo was resolved.
--- 3. The repo path's shape (nested => GitLab). Catches repos reached via a `guh://` URI or a
---    bare slug, which carry no host and so are never registered.
--- 4. The session default (see `M.default_provider`).
---
--- @return 'github'|'gitlab'
function M.current_name()
  local override = vim.g.guh_provider
  if override == 'github' or override == 'gitlab' then
    return override
  end
  local repo = (vim.b.guh or {}).repo
  if repo then
    local entry = registry[repo]
    if entry then
      return entry.provider
    end
    local implied = provider_for_path(repo)
    if implied then
      return implied
    end
  end
  return M.default_provider
end

--- The provider module for the current context.
--- @return table
function M.current()
  return M.get(M.current_name())
end

--- Feature capabilities of the current provider.
--- @return table<string, boolean>
function M.caps()
  return M.current().caps()
end

--- Gets the provider that owns `bin`, or nil. Safe to call from a fast event context.
---
--- @param bin string argv[1] (e.g. "gh", "glab").
--- @return table?
function M.for_cmd(bin)
  for name, b in pairs(binaries) do
    if b == bin then
      local ok, mod = pcall(M.get, name)
      return ok and mod or nil
    end
  end
end

return M
