# Sourced by the scripts that build PiDF or run its tests, once they are in
# the project folder: nothing they or their tools create outside it stays on
# the Mac when the script ends, also when it fails.
#   generate      XcodeGen, without the folder it leaves in the temporary folder
#   xcbuild ...   xcodebuild, with its temporary files in build/tmp
SYSTEM_TEMP="$(getconf DARWIN_USER_TEMP_DIR)"
mkdir -p build/tmp

generate() {
  command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
  local result=0
  xcodegen generate --quiet &
  local pid=$!
  wait $pid || result=$?
  # XcodeGen leaves an empty folder named <UUID>-<its process>-<number>.
  rmdir "$SYSTEM_TEMP"????????-????-????-????-????????????-$pid-*(N/) 2>/dev/null || true
  return $result
}

xcbuild() { TMPDIR="$PWD/build/tmp/" xcodebuild "$@" }

tidy() {
  setopt local_options no_err_exit  # one step failing doesn't skip the rest
  ./scripts/forget-builds.sh  # keep build copies out of "Open With"
  # What the tests keep outside the project. They remove it themselves when
  # the run ends (Tests/Scratch.swift); this is for a run that crashed or
  # was stopped, and for the suite PiDF falls back to when it hosts tests.
  defaults delete PiDFTests 2>/dev/null
  rm -rf ~/Library/Preferences/PiDFTests.plist "${SYSTEM_TEMP}PiDFTests" "${SYSTEM_TEMP}com.ivanjlm.pidf.savedState"
  # Xcode compiles the asset catalog through a helper that stays running for
  # this folder, with pipes and a folder in the temporary folder: stop it.
  local pid pipes
  for pid in $(pgrep -x ibtoold); do
    [[ " $(ps eww -o command= -p $pid) " == *" PWD=$PWD "* ]] || continue
    pipes=(${(f)"$(lsof -p $pid -Fn 2>/dev/null | sed -n 's/^n//p' | grep -F -- '-IBTOOLD-')"})
    kill $pid 2>/dev/null
    for _ in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
    rm -rf "${SYSTEM_TEMP}ibtoold-$pid" $pipes
  done
  pgrep -xq ibtoold || rmdir "${SYSTEM_TEMP}InterfaceBuilderImages" 2>/dev/null
  rm -rf build/tmp
}
trap tidy EXIT
