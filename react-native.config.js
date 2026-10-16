// https://github.com/react-native-community/cli/blob/main/docs/dependencies.md
// The OCR spike is Android-only: iOS uses Apple Vision, so the module is not linked there.
module.exports = {
  dependency: {
    platforms: {
      ios: null,
      android: {},
    },
  },
};
