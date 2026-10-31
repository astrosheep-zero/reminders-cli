# Install reminder

Requires Apple silicon, macOS 26 or later, and a Swift 6.2+ toolchain (Xcode or Command Line Tools). Private ReminderKit behavior can change between macOS versions.

## Homebrew

```sh
brew install astrosheep-zero/tap/reminder
reminder --help
reminder doctor --json
reminder setup
```

The tap builds from source and installs `Reminder.app` inside the formula's `libexec` directory. The `reminder` command is an exec wrapper that keeps the executable inside its application bundle. Installation does not launch the app, request Reminders access, or change keychains. Run `setup` yourself to request full Reminders access. Normal commands refuse when access is missing.

Homebrew builds use ad-hoc signing. They are not Developer ID signed or notarized, and upgrades may require granting access again. For a persistent signing identity, use the source build below with an existing certificate. The tool does not create or install signing certificates.

## Build from source

```sh
git clone https://github.com/astrosheep-zero/reminders-cli.git
cd reminders-cli
bash scripts/test.sh
bash scripts/build-app.sh
./dist/reminder --help
./dist/reminder doctor --json
./dist/reminder setup
```

By default the build reads an existing local certificate fingerprint from `~/.config/reminders-cli/signing-identity`, or uses ad-hoc signing if no local identity is configured. An explicit environment variable takes precedence:

```sh
SIGNING_IDENTITY='YOUR_EXISTING_CERTIFICATE_FINGERPRINT' bash scripts/build-app.sh
```

Keep the generated `dist/reminder` wrapper beside `dist/Reminder.app`. You can invoke that wrapper by absolute path. The build never installs into Applications or changes your PATH. See [README](../README.md) for signing behavior and diagnostics.

## MCP client configuration

Use the same installed executable with the `mcp` argument. For example, on a standard Apple silicon Homebrew installation:

```json
{
  "mcpServers": {
    "reminders": {
      "command": "/opt/homebrew/bin/reminder",
      "args": ["mcp"]
    }
  }
}
```

For a source build, set `command` to the absolute path of `dist/reminder`. Run `setup` explicitly before using tools; MCP startup does not request permission. MCP uses standard input/output, so launch it through your MCP client and keep stdout reserved for protocol messages.

## Current limitations

Explicit image-byte reads have failed with `NSCocoaErrorDomain/257` in local live testing. Ordinary reminder reads and adding/removing images do not rely on that read path. A follow-up will identify the cause and provide an authorization entry point or verified repair instructions; no particular additional permission is currently established as a fix. Cross-device iCloud delivery has not been independently verified.
