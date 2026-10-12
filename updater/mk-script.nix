{
  replaceVarsWith,
  runCommand,
  shellcheck,
}:
# Substitutes the @name@ placeholders of an executable busybox sh script, then fails the build when
# shellcheck (busybox dialect) objects to the result.
{ src, replacements }:
let
  script = replaceVarsWith {
    inherit src replacements;
    isExecutable = true;
  };
in
runCommand (baseNameOf src) { nativeBuildInputs = [ shellcheck ]; } ''
  shellcheck --shell=busybox ${script}
  cp ${script} $out
''
