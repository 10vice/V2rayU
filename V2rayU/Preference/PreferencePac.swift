//
//  Preferences.swift
//  V2rayU
//
//  Created by yanue on 2018/10/19.
//  Copyright © 2018 yanue. All rights reserved.
//

import Cocoa
import Preferences
import Alamofire

let PACRulesDirPath = AppResourcesPath + "/pac/"
let PACUserRuleFilePath = PACRulesDirPath + "user-rule.txt"
let PACFilePath = PACRulesDirPath + "proxy.pac"
var PACUrl = "http://127.0.0.1:" + String(HttpServerPacPort) + "/pac/proxy.pac"
let PACAbpFile = PACRulesDirPath + "abp.js"
let GFWListFilePath = PACRulesDirPath + "gfwlist.txt"
let GFWListURL = "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"

final class PreferencePacViewController: NSViewController, PreferencePane {
    let preferencePaneIdentifier = PreferencePane.Identifier.pacTab
    let preferencePaneTitle = "Pac"
    let toolbarItemIcon = NSImage(named: NSImage.bookmarksTemplateName)!

    @IBOutlet weak var tips: NSTextField!

    override var nibName: NSNib.Name? {
        return "PreferencePac"
    }

    @IBOutlet weak var gfwPacListUrl: NSTextField!
    @IBOutlet var userRulesView: NSTextView!

    override func viewDidLoad() {
        super.viewDidLoad()
        // fix: https://github.com/sindresorhus/Preferences/issues/31
        self.preferredContentSize = NSMakeSize(self.view.frame.size.width, self.view.frame.size.height);
        self.tips.stringValue = ""

        let gfwUrl = UserDefaults.get(forKey: .gfwPacListUrl)
        if gfwUrl != nil {
            gfwPacListUrl.stringValue = gfwUrl!
        } else {
            gfwPacListUrl.stringValue = GFWListURL
        }

        // read userRules from UserDefaults
        let txt = UserDefaults.get(forKey: .userRules)
        var userRuleTxt = """
                          ! Put user rules line by line in this file.
                          ! See https://adblockplus.org/en/filter-cheatsheet

                          """
        if txt != nil {
            if txt!.count > 0 {
                userRuleTxt = txt!
            }
        } else {
            let str = try? String(contentsOfFile: PACUserRuleFilePath, encoding: String.Encoding.utf8)
            if str?.count ?? 0 > 0 {
                userRuleTxt = str!
            }
        }
        userRulesView.string = userRuleTxt
    }

    @IBAction func viewPacFile(_ sender: Any) {
        guard let url = URL(string: PACUrl) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @IBAction func updatePac(_ sender: Any) {
        self.tips.stringValue = "Updating Pac Rules ..."

        if let str = userRulesView?.string {
            do {
                // save user rules into UserDefaults
                UserDefaults.set(forKey: .userRules, value: str)

                try str.data(using: String.Encoding.utf8)?.write(to: URL(fileURLWithPath: PACUserRuleFilePath), options: .atomic)

                UpdatePACFromGFWList()

                if GeneratePACFile() {
                    // Popup a user notification
                    self.tips.stringValue = "PAC has been updated by User Rules."
                } else {
                    self.tips.stringValue = "It's failed to update PAC by User Rules."
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    // your code here
                    self.tips.stringValue = ""
                }
            } catch {
            }
        }
    }
}

// Because of LocalSocks5.ListenPort may be changed
func GeneratePACFile() -> Bool {
    let socks5Address = "127.0.0.1"

    let sockPort = UserDefaults.get(forKey: .localSockPort) ?? "1080"

    // permission
    _ = shell(launchPath: "/bin/bash", arguments: ["-c", "cd " + AppResourcesPath + " && /bin/chmod -R 755 ./pac"])

    do {
        let gfwlist = try String(contentsOfFile: GFWListFilePath, encoding: String.Encoding.utf8)
        if let data = Data(base64Encoded: gfwlist, options: .ignoreUnknownCharacters) {
            let str = String(data: data, encoding: String.Encoding.utf8)
            var lines = str!.components(separatedBy: CharacterSet.newlines)

            // read userRules from UserDefaults
            let userRules = UserDefaults.get(forKey: .userRules)
            if userRules != nil {
                try userRules!.data(using: String.Encoding.utf8)?.write(to: URL(fileURLWithPath: PACUserRuleFilePath), options: .atomic)
            }

            do {
                let userRuleStr = try String(contentsOfFile: PACUserRuleFilePath, encoding: String.Encoding.utf8)
                let userRuleLines = userRuleStr.components(separatedBy: CharacterSet.newlines)

                lines = userRuleLines + lines
            } catch {
                NSLog("Not found user-rule.txt")
            }
            // Filter empty and comment lines
            lines = lines.filter({ (s: String) -> Bool in
                if s.isEmpty {
                    return false
                }
                let c = s[s.startIndex]
                if c == "!" || c == "[" {
                    return false
                }
                return true
            })

            do {
                // rule lines to json array
                let rulesJsonData: Data = try JSONSerialization.data(withJSONObject: lines, options: .prettyPrinted)
                let rulesJsonStr = String(data: rulesJsonData, encoding: String.Encoding.utf8)

                // Get raw pac js
                let jsData = try? Data(contentsOf: URL.init(fileURLWithPath: PACAbpFile))
                var jsStr = String(data: jsData!, encoding: String.Encoding.utf8)

                // Replace rules placeholder in pac js
                jsStr = jsStr!.replacingOccurrences(of: "__RULES__", with: rulesJsonStr!)
                // Replace __SOCKS5PORT__ palcholder in pac js
                jsStr = jsStr!.replacingOccurrences(of: "__SOCKS5PORT__", with: "\(sockPort)")
                // Replace __SOCKS5ADDR__ palcholder in pac js
                var sin6 = sockaddr_in6()
                if socks5Address.withCString({ cstring in inet_pton(AF_INET6, cstring, &sin6.sin6_addr) }) == 1 {
                    jsStr = jsStr!.replacingOccurrences(of: "__SOCKS5ADDR__", with: "[\(socks5Address)]")
                } else {
                    jsStr = jsStr!.replacingOccurrences(of: "__SOCKS5ADDR__", with: socks5Address)
                }

                // Write the pac js to file.
                try jsStr!.data(using: String.Encoding.utf8)?.write(to: URL(fileURLWithPath: PACFilePath), options: .atomic)
                return true
            } catch {

            }
        }

    } catch {
        NSLog("Not found gfwlist.txt")
    }
    return false
}

func UpdatePACFromGFWList() {
    // Make the dir if rulesDirPath is not exesited.
    if !FileManager.default.fileExists(atPath: PACRulesDirPath) {
        do {
            try FileManager.default.createDirectory(atPath: PACRulesDirPath
                , withIntermediateDirectories: true, attributes: nil)
        } catch {
        }
    }

    Alamofire.request(GFWListURL).responseString {
        response in
        if response.result.isSuccess {
            if let v = response.result.value {
                do {
                    try v.write(toFile: GFWListFilePath, atomically: true, encoding: String.Encoding.utf8)

                    if GeneratePACFile() {
                        // Popup a user notification
                        let notification = NSUserNotification()
                        notification.title = "PAC has been updated by latest GFW List."
                        NSUserNotificationCenter.default.deliver(notification)
                    }
                } catch {

                }
            }
        } else {
            // Popup a user notification
            let notification = NSUserNotification()
            notification.title = "Failed to download latest GFW List."
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}
