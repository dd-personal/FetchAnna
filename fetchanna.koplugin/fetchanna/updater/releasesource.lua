-- The GitHub repository FetchAnna updates itself from, as "owner/name". Each of its releases has fetchanna.koplugin.zip
-- (see PluginUpdater). A fork should name its own, or nil to turn self-updating off, so it never installs this
-- project's releases over itself. The Release workflow only publishes a build whose repo is the one releasing it.
return {
    repo = "dd-personal/FetchAnna",
}
