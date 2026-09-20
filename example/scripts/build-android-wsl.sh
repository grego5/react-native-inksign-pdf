#!/usr/bin/env bash
set -euo pipefail

source_repo=''
mirror_repo="${HOME}/projects/inksign-pdf-example"
build_task=':app:assembleDebug'
build_variant='debug'
output_apk=''
tracing=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      source_repo="$2"
      shift 2
      ;;
    --task)
      build_task="$2"
      shift 2
      ;;
    --variant)
      build_variant="$2"
      shift 2
      ;;
    --output)
      output_apk="$2"
      shift 2
      ;;
    --tracing)
      tracing=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$source_repo" ]]; then
  echo '--source is required' >&2
  exit 2
fi

if [[ ! -d "$source_repo" ]]; then
  echo "Source repository does not exist: $source_repo" >&2
  exit 2
fi

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [[ ! -d "$android_sdk" ]]; then
  echo "Android SDK does not exist: $android_sdk" >&2
  echo 'Install the Linux Android SDK in WSL or set ANDROID_HOME.' >&2
  exit 1
fi

if [[ "$android_sdk" == /mnt/* ]]; then
  echo "The WSL build requires a Linux Android SDK, not a Windows SDK: $android_sdk" >&2
  exit 1
fi

export ANDROID_HOME="$android_sdk"
export ANDROID_SDK_ROOT="$android_sdk"
if [[ "$build_variant" == release ]]; then
  export NODE_ENV=production
else
  export NODE_ENV=development
fi

# npm records GitHub shorthand dependencies as SSH URLs. Use HTTPS for the
# public repository so WSL does not require SSH access to github.com.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0='url.https://github.com/.insteadOf'
export GIT_CONFIG_VALUE_0='ssh://git@github.com/'
export GIT_CONFIG_KEY_1='url.https://github.com/.insteadOf'
export GIT_CONFIG_VALUE_1='git@github.com:'

if ! command -v rsync >/dev/null 2>&1; then
  echo 'rsync is required in WSL. Install it with: sudo apt install rsync' >&2
  exit 1
fi

mkdir -p "$mirror_repo"

rsync -a --delete \
  --exclude '.git/' \
  --exclude '.wsl-build-state/' \
  --exclude 'node_modules/' \
  --exclude '.gradle/' \
  --exclude '.cxx/' \
  --exclude 'android/' \
  --exclude 'ios/' \
  --exclude 'build/' \
  --exclude 'dist/' \
  "$source_repo/" "$mirror_repo/"

state_dir="$mirror_repo/.wsl-build-state"
mkdir -p "$state_dir"

install_if_lock_changed() {
  local project_dir="$1"
  local stamp_name="$2"
  local lock_file="$project_dir/package-lock.json"
  local stamp_file="$state_dir/$stamp_name.sha256"

  if [[ ! -f "$lock_file" ]]; then
    return
  fi

  local lock_hash
  lock_hash="$(sha256sum "$lock_file" | awk '{print $1}')"
  if [[ -d "$project_dir/node_modules" && -f "$stamp_file" && "$(cat "$stamp_file")" == "$lock_hash" ]]; then
    return
  fi

  echo "Installing dependencies in $project_dir"
  (cd "$project_dir" && npm ci)
  printf '%s\n' "$lock_hash" > "$stamp_file"
}

install_if_lock_changed "$mirror_repo" example

echo 'Generating the standalone Android project'
(cd "$mirror_repo" && npx expo prebuild --platform android --no-install)

if [[ "$tracing" == true ]]; then
  export EXPO_PUBLIC_ENABLE_DEBUG_RECORDER=true
else
  export EXPO_PUBLIC_ENABLE_DEBUG_RECORDER=false
fi

gradlew="$mirror_repo/android/gradlew"
if [[ ! -f "$gradlew" ]]; then
  echo "Android Gradle wrapper is missing: $gradlew" >&2
  exit 1
fi

chmod +x "$gradlew"
sed -i 's/\r$//' "$gradlew"
printf 'sdk.dir=%s\n' "$android_sdk" > "$mirror_repo/android/local.properties"

echo "Building $build_task in $mirror_repo"
gradle_arguments=("$build_task" '--no-daemon' '--console=plain')
if [[ "$build_variant" == release ]]; then
  gradle_arguments+=('-PreactNativeArchitectures=arm64-v8a')
else
  gradle_arguments+=('-PreactNativeArchitectures=arm64-v8a,x86_64')
fi
(cd "$mirror_repo/android" && ./gradlew "${gradle_arguments[@]}")

if [[ -z "$output_apk" ]]; then
  output_apk="$source_repo/build/app-${build_variant}.apk"
fi

mirror_apk="$mirror_repo/android/app/build/outputs/apk/${build_variant}/app-${build_variant}.apk"
if [[ -f "$mirror_apk" ]]; then
  mkdir -p "$(dirname "$output_apk")"
  cp "$mirror_apk" "$output_apk"
  echo "APK copied to $output_apk"
else
  echo "Build completed, but APK was not found: $mirror_apk" >&2
  exit 1
fi
