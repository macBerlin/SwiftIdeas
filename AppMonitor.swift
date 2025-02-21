import Foundation

// Michael Rieder 02/2025

// Idea to monitor VPP Installations 
// can be run as launchagent (no root priviliges required)

// 1. Monitor folders _In Progress (InstallEnterpriseCommand) and _Completed
// This demo require (lazy implementation):
// https://github.com/swiftDialog/swiftDialog/releases/download/v2.5.5/dialog-2.5.5-4802.pkg
// https://github.com/kcrawford/dockutil/releases/download/3.1.3/dockutil-3.1.3.pkg
// + Allow Notifications for dialog in System Settings
//
// Build binary: swiftc -o AppMonitor AppMonitor.swift
// run in debug mode: ./AppMonitor -d 

// Define watched directories
let inProgressDir = "/private/var/db/ConfigurationProfiles/Settings/Managed Applications/Device/_In Progress"
let completedDir = "/private/var/db/ConfigurationProfiles/Settings/Managed Applications/Device/_Completed"
let deviceDir = "/private/var/db/ConfigurationProfiles/Settings/Managed Applications/Device"

// Track processed apps to prevent duplicate notifications
var processedApps = Set<String>()

// Debug mode flag (enabled via `-d` argument)
var debugMode = CommandLine.arguments.contains("-d")

// Function to log messages
func debugLog(_ message: String) {
    if debugMode {
        print("[DEBUG]  \(message)")
    }
}

// Class to Watch Folder Changes
class FolderWatcher {
    let source: DispatchSourceFileSystemObject

    init(path: String) {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            fatalError("❌ Failed to open directory: \(path)")
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: DispatchQueue.global())

        source.setEventHandler {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: path)
            contents?.forEach { file in
                if file.hasSuffix(".plist") {
                    debugLog("📄 New plist detected in \(path): \(file)")
                    processPlist(at: "\(path)/\(file)", completed: path.contains("_Completed"))
                }
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
    }
}

// Function to Process Plist Files
func processPlist(at path: String, completed: Bool = false) {
    guard let plistData = FileManager.default.contents(atPath: path) else {
        debugLog("❌ Failed to read plist: \(path)")
        return
    }

    do {
        if let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
           let mdmOptions = plist["MDMOptions"] as? [String: Any],
           let iTunesStoreID = mdmOptions["iTunesStoreID"] as? Int {

            let storeIDString = String(iTunesStoreID)

            if completed {
                if processedApps.contains(storeIDString) {
                    debugLog("✅ App Installed: \(storeIDString)")
                    fetchAppDetails(iTunesStoreID: iTunesStoreID, completed: true)
                    processedApps.remove(storeIDString) // Remove from tracking
                } else {
                    debugLog("⏭️ Skipping \(storeIDString) - Not detected in '_In Progress'")
                }
            } else {
                if !processedApps.contains(storeIDString) {
                    debugLog("📥 New app detected with iTunesStoreID: \(iTunesStoreID)")
                    processedApps.insert(storeIDString)
                    fetchAppDetails(iTunesStoreID: iTunesStoreID)
                } else {
                    debugLog("Skipping already processed app: \(storeIDString)")
                }
            }
        } else {
            debugLog("❌ MDMOptions or iTunesStoreID missing in plist.")
        }
    } catch {
        debugLog("❌ Error parsing plist: \(error.localizedDescription)")
    }
}

// Fetch App Details from iTunes API
func fetchAppDetails(iTunesStoreID: Int, completed: Bool = false) {
    let url = URL(string: "https://itunes.apple.com/lookup?id=\(iTunesStoreID)")!

    debugLog("🌍 Fetching app details from: \(url.absoluteString)")

    let task = URLSession.shared.dataTask(with: url) { data, response, error in
        guard let data = data, error == nil else {
            print("❌ Error fetching app data: \(error?.localizedDescription ?? "Unknown error")")
            return
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let results = json["results"] as? [[String: Any]], let appInfo = results.first {

                let trackName = appInfo["trackName"] as? String ?? "Unknown App"
                let artistName = appInfo["artistName"] as? String ?? ""
                let artworkUrl = appInfo["artworkUrl512"] as? String
                let bundleId = appInfo["bundleId"] as? String ?? ""

                debugLog("📦 App Found: \(trackName), Bundle ID: \(bundleId), Image URL: \(artworkUrl ?? "None")")

                if completed {
                    sendNotification(title: "Installation Completed", body: "Installation of \(trackName) is now finished.", imageURL: artworkUrl, vendor: artistName)
                    findAppPathAndAddToDock(bundleId: bundleId)
                } else {
                    sendNotification(title: "Installation in Progress", body: "Installation for \(trackName) is now in progress.", imageURL: artworkUrl, vendor: artistName)
                }
            } else {
                debugLog("❌ Invalid response from iTunes API")
            }
        } catch {
            print("❌ JSON Parsing Error: \(error.localizedDescription)")
        }
    }

    task.resume()
}

// Function to Find App Path in `{bundleId}.plist` and Add to Dock
func findAppPathAndAddToDock(bundleId: String) {
    let plistPath = "\(deviceDir)/\(bundleId).plist"

    guard let plistData = FileManager.default.contents(atPath: plistPath) else {
        debugLog("❌ No corresponding plist found for \(bundleId)")
        return
    }

    do {
        if let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            for (_, value) in plist { // Array key is unknown, so iterate over all keys
                if let array = value as? [[String: Any]], let firstItem = array.first, let appPath = firstItem["Path"] as? String {
                    debugLog("📌 App Path Found: \(appPath)")
                    addAppToDock(appPath: appPath)
                    return
                }
            }
            debugLog("❌ No 'Path' key found in plist for \(bundleId)")
        }
    } catch {
        debugLog("❌ Error parsing \(bundleId).plist: \(error.localizedDescription)")
    }
}

// Function to Add App to Dock
func addAppToDock(appPath: String) {
    guard let user = getLoggedInUser() else {
        debugLog("❌ No logged-in user found.")
        return
    }

    let dockutilCommand = "sudo -u \(user) /usr/local/bin/dockutil --add \"\(appPath)\""

    let process = Process()
    process.launchPath = "/bin/bash"
    process.arguments = ["-c", dockutilCommand]
    process.launch()

    debugLog("📌 Added \(appPath) to Dock for user \(user).")
}

// Function to Get Logged-in User
func getLoggedInUser() -> String? {
    let process = Process()
    process.launchPath = "/usr/bin/stat"
    process.arguments = ["-f", "%Su", "/dev/console"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// Function to Send Notifications
func sendNotification(title: String, body: String, imageURL: String?, vendor: String) {
    guard let user = getLoggedInUser() else {
        debugLog("❌ No logged-in user found.")
        return
    }

    let notificationScript: String
    var iconPath = ""

    if let imageURL = imageURL, let url = URL(string: imageURL) {
        let tempImagePath = "/tmp/app_icon.png"
        if let imageData = try? Data(contentsOf: url) {
            try? imageData.write(to: URL(fileURLWithPath: tempImagePath))
            iconPath = "-i \(tempImagePath)"
        }
    }

    notificationScript = """
    sudo -u \(user) /usr/local/bin/dialog --notification "\(body)" --message "\(body)" --title "\(title)" \(iconPath) --subtitle "\(vendor)"
    """

    let process = Process()
    process.launchPath = "/bin/bash"
    process.arguments = ["-c", notificationScript]
    process.launch()

    debugLog("📢 Sent notification via `dialog`: \(title) - \(body) with icon at \(iconPath)")
}

// Start Folder Watchers
let inProgressWatcher = FolderWatcher(path: inProgressDir)
let completedWatcher = FolderWatcher(path: completedDir)

// Keep Running
RunLoop.main.run()
