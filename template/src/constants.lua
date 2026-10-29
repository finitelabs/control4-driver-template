--- Constants used throughout the driver.

return {
  --- Show a property in the Composer UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Hide a property in the Composer UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- Every .c4z the repo builds, companions included: the files the GitHub updater installs, and the drivers whose
  --- items keep the update settings the same.
  --- @type string[]
  DRIVER_FILENAMES = {},
}
