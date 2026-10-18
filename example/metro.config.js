const path = require('node:path')
const { getDefaultConfig } = require('expo/metro-config')

const projectRoot = __dirname
const config = getDefaultConfig(projectRoot)

// Resolve all package imports from the app install, including imports made
// by the linked library and Nitro. This keeps React and React Native shared.
config.resolver.disableHierarchicalLookup = true
config.resolver.nodeModulesPaths = [path.join(projectRoot, 'node_modules')]

module.exports = config
