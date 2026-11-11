--- Dispatches to the active provider backend (see `guh.provider`).
---
--- This module is deliberately a thin shim: `guh.pr`, `guh.comments`, `guh.state` and
--- `plugin/guh.lua` call `gh.<fn>(...)` and remain provider-agnostic. Every access is forwarded to
--- the provider for the current context, so both functions and the mutable data fields
--- (`rate_limit`, `state_hl`, `reaction_emoji`) resolve correctly — providers *reassign* those
--- fields rather than mutating them in place.
---
--- Note: the provider functions are called as plain fields (`gh.foo(...)`, not `gh:foo(...)`), so
--- they receive no `self`; each provider closes over its own module table.

local provider = require('guh.provider')

local M = setmetatable({}, {
  __index = function(_, k)
    return provider.current()[k]
  end,
})

--- The active provider backend. Escape hatch for callers needing `caps()` or provider-specific
--- methods.
---
--- @return table
function M.provider()
  return provider.current()
end

--- Name of the active provider ('github'|'gitlab').
---
--- @return 'github'|'gitlab'
function M.name()
  return provider.current_name()
end

--- Feature capabilities of the active provider, so callers can degrade instead of erroring.
---
--- @return table<string, boolean>
function M.caps()
  return provider.caps()
end

return M
