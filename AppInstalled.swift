import Foundation



// macOS App Check Demo -> Required installed bundle_id

// 1. Check if the bundle is installed in pkgutil database
// 2. Check if the installed package has file with .app (If not we expect some payload free packages or other extensions)
// 3. Check if the extracted App Path exist in /Applications
// 4. If not check with spotlight if the app is may be moved or installed outside of Applications
// 5. Return the result and from here you can set the right button text



/// Executes a shell command and returns the output as a string.
/// - Parameter command: The shell command to execute.
/// - Returns: The output of the command as a trimmed string, or `nil` if empty.
func runShellCommand(_ command: String) -> String? {
    let task = Process()
    let pipe = Pipe()
    
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    task.standardOutput = pipe
    task.standardError = pipe
    
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == false ? output : nil
}

/// Retrieves the correct package ID from `pkgutil` using a case-insensitive search.
/// - Parameter packageID: The package identifier (case-insensitive).
/// - Returns: The correctly formatted package ID, or `nil` if not found.
func getCorrectPackageID(packageID: String) -> String? {
    let command = "/usr/sbin/pkgutil --pkgs | grep -i \(packageID)"
    return runShellCommand(command)
}

/// Extracts the application name from a full path.
/// - Parameter path: The full path to the application bundle (e.g., `Applications/Apple Configurator.app`).
/// - Returns: The extracted app name (e.g., `Apple Configurator.app`), or `nil` if the path is invalid.
func extractAppName(from path: String) -> String? {
    let components = path.split(separator: "/")
    return components.last.map(String.init) // Return last part (app name)
}

/// Checks if an application exists in the `/Applications/` directory.
/// - Parameter appName: The name of the application bundle (e.g., `Microsoft Word.app`).
/// - Returns: The full path to the app if it exists, otherwise `nil`.
func getAppPathInApplicationsFolder(appName: String) -> String? {
    let appPath = "/Applications/\(appName)"
    return FileManager.default.fileExists(atPath: appPath) ? appPath : nil
}

/// Searches for an application using Spotlight (`mdfind`).
/// - Parameter appName: The name of the application bundle (e.g., `Microsoft Word.app`).
/// - Returns: The full path of the found application, or `nil` if not found.
func findAppPathWithSpotlight(appName: String) -> String? {
    let command = "mdfind \"kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '\(appName)'\""
    if let result = runShellCommand(command) {
        let paths = result.components(separatedBy: "\n")
        return paths.first // Return the first found path
    }
    return nil
}

/// Determines if a package-installed app exists and returns its path.
/// - Parameter packageID: The package identifier (case-insensitive).
/// - Returns: The full path to the installed app if found, otherwise `nil`.
func getInstalledAppPath(packageID: String) -> String? {
    // Ensure we have the correct package ID with the correct casing
    guard let correctedPackageID = getCorrectPackageID(packageID: packageID) else {
        print("⚠️ No package found for identifier: \(packageID)")
        return nil
    }
    
    print("✅ Found correct package ID: \(correctedPackageID)")

    // Get the first .app file from the installed package
    guard let packageFile = runShellCommand("/usr/sbin/pkgutil --files \(correctedPackageID) | grep \".app\" | head -1"),
          let appName = extractAppName(from: packageFile) else {
        print("⚠️ No .app file found for package \(correctedPackageID)")
        return nil
    }
    
    print("Extracted App Name: \(appName)")
    
    // First, check if the app is located in the `/Applications/` directory
    if let appPath = getAppPathInApplicationsFolder(appName: appName) {
        print("✅ App is installed in: \(appPath)")
        return appPath
    }
    
    // If not found in `/Applications/`, try searching with `mdfind`
    if let appPath = findAppPathWithSpotlight(appName: appName) {
        print("✅ App found with Spotlight at: \(appPath)")
        return appPath
    }
    
    print("❌ App \(appName) is NOT installed.")
    return nil
}

// Example Usage case insensitve
let packageID = "com.google.chrome" 
if let appPath = getInstalledAppPath(packageID: packageID) {
    print("Button-Text: re-install -> Package app is installed at: \(appPath)")
          //-> Button name should be "Re-Install"
} else {
    print("Button-Text: install -> Package app is NOT installed.")
       // -> Button name should be "Install"
}
