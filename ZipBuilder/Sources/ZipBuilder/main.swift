/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

// Delete the cache directory, if it exists.
do {
  let cacheDir = try FileManager.default.firebaseCacheDirectory()
  FileManager.default.removeDirectoryIfExists(at: cacheDir)
} catch {
  fatalError("Could not remove the cache before packaging the release: \(error)")
}

// Get the launch arguments, parsed by user defaults.
let args = LaunchArgs()

// Keep timing for how long it takes to build the zip file for information purposes.
let buildStart = Date()
var cocoaPodsUpdateMessage: String = ""

// Do a Pod Update if requested.
if args.updatePodRepo {
  CocoaPodUtils.updateRepos()
  cocoaPodsUpdateMessage = "CocoaPods took \(-buildStart.timeIntervalSinceNow) seconds to update."
}

var paths = ZipBuilder.FilesystemPaths(templateDir: args.templateDir)
paths.allSDKsPath = args.allSDKsPath
paths.currentReleasePath = args.currentReleasePath
paths.logsOutputDir = args.outputDir?.appendingPathComponent("build_logs")
let builder = ZipBuilder(paths: paths, customSpecRepos: args.customSpecRepos)

do {
  // Build the zip file and get the path.
  let projectDir = FileManager.default.temporaryDirectory(withName: "project")
  let artifacts = try builder.buildAndAssembleRelease(inProjectDir: projectDir)
  let firebaseVersion = artifacts.firebaseVersion
  let location = artifacts.outputDir
  print("Firebase \(firebaseVersion) directory is ready to be packaged: \(location)")

  // Package carthage if it's enabled.
  var carthageRoot: URL?
  if let carthageJSONDir = args.carthageDir {
    do {
      print("Creating Carthage release...")
      // Create a copy of the release directory since we'll be modifying it.
      let carthagePath =
        location.deletingLastPathComponent().appendingPathComponent("carthage_build")
      let fileManager = FileManager.default
      fileManager.removeDirectoryIfExists(at: carthagePath)
      try fileManager.copyItem(at: location, to: carthagePath)

      // Package the Carthage distribution with the current directory structure.
      let carthageDir = location.deletingLastPathComponent().appendingPathComponent("carthage")
      fileManager.removeDirectoryIfExists(at: carthageDir)
      var output = carthageDir.appendingPathComponent(firebaseVersion)
      if let rcNumber = args.rcNumber {
        output.appendPathComponent("rc\(rcNumber)")
      } else {
        output.appendPathComponent("latest-non-rc")
      }
      try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
      CarthageUtils.generateCarthageRelease(fromPackagedDir: carthagePath,
                                            templateDir: args.templateDir,
                                            jsonDir: carthageJSONDir,
                                            firebaseVersion: firebaseVersion,
                                            coreDiagnosticsPath: artifacts.carthageDiagnostics,
                                            outputDir: output)

      // Remove the duplicated Carthage build directory.
      fileManager.removeDirectoryIfExists(at: carthagePath)
      print("Done creating Carthage release! Files written to \(output)")

      // Save the directory for later copying.
      carthageRoot = carthageDir
    } catch {
      fatalError("Could not copy output directory for Carthage build: \(error)")
    }
  }

  // Prepare the release directory for zip packaging.
  do {
    // Move the Resources out of each directory in order to maintain the existing Zip structure.
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(atPath: location.path)
    for fileOrFolder in contents {
      let fullPath = location.appendingPathComponent(fileOrFolder)

      // Ignore any files.
      guard fileManager.isDirectory(at: fullPath) else { continue }

      // Move all the bundles in the frameworks out to a common "Resources" directory to match the
      // existing Zip structure.
      let resourcesDir = fullPath.appendingPathComponent("Resources")
      _ = try ResourcesManager.moveAllBundles(inDirectory: fullPath, to: resourcesDir)
    }
  }

  print("Attempting to Zip the directory...")
  var candidateName = "Firebase-\(firebaseVersion)"
  if let rcNumber = args.rcNumber {
    candidateName += "-rc\(rcNumber)"
  }
  candidateName += ".zip"
  let zipped = Zip.zipContents(ofDir: location, name: candidateName)

  // If an output directory was specified, copy the Zip file to that directory. Otherwise just print
  // the location for further use.
  if let outputDir = args.outputDir {
    do {
      // Clear out the output directory if it exists.
      FileManager.default.removeDirectoryIfExists(at: outputDir)
      try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

      // We want the output to be in the X_Y_Z directory.
      let underscoredVersion = firebaseVersion.replacingOccurrences(of: ".", with: "_")
      let versionedOutputDir = outputDir.appendingPathComponent(underscoredVersion)
      try FileManager.default.createDirectory(at: versionedOutputDir,
                                              withIntermediateDirectories: true)
      let destination = versionedOutputDir.appendingPathComponent(zipped.lastPathComponent)
      try FileManager.default.copyItem(at: zipped, to: destination)
    } catch {
      fatalError("Could not copy Zip file to output directory: \(error)")
    }

    // Move the Carthage directory, if it exists.
    if let carthageOutput = carthageRoot {
      do {
        let carthageDir = outputDir.appendingPathComponent("carthage")
        try FileManager.default.copyItem(at: carthageOutput, to: carthageDir)
      } catch {
        fatalError("Could not copy Carthage output to directory: \(error)")
      }
    }
  } else {
    print("Success! Zip file can be found at \(zipped.path)")
  }

  // Get the time since the start of the build to get the full time.
  let secondsSinceStart = -Int(buildStart.timeIntervalSinceNow)
  print("""
  Time profile:
    It took \(secondsSinceStart) seconds (~\(secondsSinceStart / 60)m) to build the zip file.
    \(cocoaPodsUpdateMessage)
  """)
} catch {
  let secondsSinceStart = -buildStart.timeIntervalSinceNow
  print("""
  Time profile:
    The build failed in \(secondsSinceStart) seconds (~\(secondsSinceStart / 60)m).
    \(cocoaPodsUpdateMessage)
  """)
  fatalError("Could not build the zip file: \(error)")
}
