import { type ConfigPlugin, withGradleProperties } from '@expo/config-plugins';

const gradleProperties = {
  'android.cmakeVersion': '4.1.2',
  reactNativeArchitectures: 'arm64-v8a',
};

const withGradleConfig: ConfigPlugin = (config) =>
  withGradleProperties(config, (gradleConfig) => {
    for (const [key, value] of Object.entries(gradleProperties)) {
      const property = gradleConfig.modResults.find(
        (item) => item.type === 'property' && item.key === key,
      );

      if (property?.type === 'property') {
        property.value = value;
      } else {
        gradleConfig.modResults.push({ type: 'property', key, value });
      }
    }

    return gradleConfig;
  });

export default withGradleConfig;
