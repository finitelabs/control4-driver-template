<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

# <span style="color:#17BCF2">Example Light</span>

<img alt="Example Light" src="./images/header.png" width="240"/>

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

This is the template's example Light V2 driver. Continuous integration builds it
with the `light` token, which proves the Light V2 library bundles into a `.c4z`.
It drives a color bulb held in memory, so it needs no device, and its
`driver.lua` is the shortest whole adapter over the library.

> [!NOTE]
> The example light is never installed on a controller.

# <span style="color:#17BCF2">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#17BCF2">System Requirements</span>

- Control4 OS 3.3+

# <span style="color:#17BCF2">Installer Setup</span>

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

# <span style="color:#17BCF2">Support</span>

If you have any questions or issues, you can file an issue on GitHub:

https://github.com/finitelabs/control4-driver-template/issues/new

<!-- #embed-changelog -->
