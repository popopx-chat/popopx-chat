const path = require("path")

// Tests load the locally built add-on instead of downloading the released one.  An ambient override
// of either spelling wins; a legacy SIMPLEX_* is here mirrored onto POPOPX_ so the resolver, which
// reads POPOPX_ first, sees the same path either way.
process.env.POPOPX_ADDON_PATH ??= process.env.SIMPLEX_ADDON_PATH ??= path.join(__dirname, "build", "Release", "popopx.node")

module.exports = {
  preset: "ts-jest",
  maxWorkers: 1,
  // a test with a new database runs every migration, each committed with a disk flush: seconds on slow CI runners
  testTimeout: 30000,
  testEnvironment: "node",
  transform: {
    '^.+\\.ts$': ['ts-jest', {
      tsconfig: 'tests/tsconfig.json'
    }]
  }
}
