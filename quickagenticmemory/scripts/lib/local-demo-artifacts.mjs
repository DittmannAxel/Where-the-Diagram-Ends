import { rmSync } from "node:fs";
import { relative, resolve } from "node:path";

export function localDemoArtifactRoot(artifactParent) {
  const resolvedParent = resolve(artifactParent);
  const target = resolve(resolvedParent, "local-demo");

  if (relative(resolvedParent, target) !== "local-demo") {
    throw new Error("The local demo artifact directory escaped its parent.");
  }

  return target;
}

export function resetLocalDemoArtifacts(artifactParent) {
  const target = localDemoArtifactRoot(artifactParent);
  rmSync(target, { recursive: true, force: true });
  return target;
}
