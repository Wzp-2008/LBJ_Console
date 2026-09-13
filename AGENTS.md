# Agent instructions

## Build network proxy

When Flutter, Gradle, NuGet, pub, or native-asset downloads are needed during a build or test, use the local proxy:

`http://127.0.0.1:7890`

For PowerShell commands, set `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` to this URL for the duration of the command. This proxy is a local development aid only; do not bake it into application runtime or release configuration.
