# Provenance

This public repository is a reviewable source snapshot extracted from a private CodexPro Smart local controller. The private recovery repository remains separate and contains machine-specific rollback material; it is not a dependency of this public tree.

Included here:

- the SwiftUI/AppKit control surface;
- the bounded `ControlRunner` implementation;
- the generic arm64 build script;
- the application icon;
- a synthetic adapter contract.

Excluded here:

- live LaunchAgents;
- Cloudflare tunnel configuration and credentials;
- HTTP tokens;
- private filesystem paths;
- runtime logs, chat exports, and installed application archives.
