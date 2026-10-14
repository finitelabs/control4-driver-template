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

# <span style="color:#17BCF2">Example Driver</span>

<img alt="Example Driver" src="./images/header.png" width="240"/>

______________________________________________________________________

# <span style="color:#17BCF2">Overview</span>

This is an example driver used by the template's continuous integration to
exercise the full build. It carries only the properties and handlers common to
every driver and implements no device-specific behavior.

> [!NOTE]
> The example driver is never installed on a controller. Its documentation
> carries one of each GitHub alert so CI can check how they render.

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

> [!IMPORTANT]
> Update the controller to a supported OS before adding the driver.

# <span style="color:#17BCF2">Installer Setup</span>

> [!CAUTION]
> Deleting the driver from a project also deletes its bindings and programming.

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

> [!TIP]
> To capture a log for a support request:
>
> 1. Set **Log Level** to `5 - Trace`.
> 1. Set **Log Mode** to `Print`.
> 1. Send the output from Composer's Lua tab as described under
>    [Support](#support).

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

> [!WARNING]
> `Log` and `Print and Log` write to the controller's log files. Set it back to
> `Off` when you are done.

# <span style="color:#17BCF2">Support</span>

If you have any questions or issues, you can file an issue on GitHub:

https://github.com/finitelabs/control4-driver-template/issues/new

> Include the driver version and the controller's OS version in the issue.

<!-- #embed-changelog -->
