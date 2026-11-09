#!/usr/bin/env node
// Regenerates the data this port shares with Omarchy's Elsewhen plugin:
//
//   node scripts/sync-omarchy.mjs /path/to/omarchy
//
// - world.json and cities.json are copied as they are;
// - Greetings.js is evaluated and its tables written out as greetings.json;
// - the shell catalog's `elsewhen.*` strings, plus the macOS-only strings in
//   scripts/mac-strings.json, become one Localizable.strings and
//   Localizable.stringsdict per language.

import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, "..")
const omarchy = path.resolve(process.argv[2] || "")
const plugin = path.join(omarchy, "shell/plugins/panels/elsewhen")
const i18n = path.join(omarchy, "default/i18n")

if (!fs.existsSync(path.join(plugin, "Model.js"))) {
  console.error("usage: node scripts/sync-omarchy.mjs /path/to/omarchy")
  process.exit(1)
}

const coreResources = path.join(repo, "Sources/ElsewhenCore/Resources")
const appResources = path.join(repo, "Sources/Elsewhen/Resources")
fs.mkdirSync(coreResources, { recursive: true })
fs.mkdirSync(appResources, { recursive: true })

// ---- data

for (const name of ["world.json", "cities.json"]) {
  // Re-serialised compactly so a formatting change upstream is not a diff here.
  const data = JSON.parse(fs.readFileSync(path.join(plugin, name), "utf8"))
  fs.writeFileSync(path.join(coreResources, name), JSON.stringify(data) + "\n")
}

const context = {}
vm.createContext(context)
vm.runInContext(fs.readFileSync(path.join(plugin, "Greetings.js"), "utf8"), context)
const greetings = {
  fallback: context.FALLBACK,
  languages: context.LANGUAGES,
  countries: context.COUNTRIES,
  overrides: context.OVERRIDES,
  aliasCountry: context.ALIAS_COUNTRY,
  zoneCountry: context.ZONE_COUNTRY
}
fs.writeFileSync(path.join(coreResources, "greetings.json"), JSON.stringify(greetings) + "\n")

// ---- strings

// Omarchy's catalog names languages its own way; these are the .lproj names macOS uses.
const LPROJ = { "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "no": "nb", "es-MX": "es-419" }

function flatten(object, prefix = "", out = {}) {
  for (const [key, value] of Object.entries(object)) {
    const name = prefix ? `${prefix}.${key}` : key
    const plural = value && typeof value === "object" && ("other" in value || "one" in value)
    if (value && typeof value === "object" && !plural) flatten(value, name, out)
    else out[name] = value
  }
  return out
}

const wanted = key => key.startsWith("elsewhen.") || key === "common.noMatches"
const macStrings = JSON.parse(fs.readFileSync(path.join(here, "mac-strings.json"), "utf8"))

const escape = text => String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")
const xml = text => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

// Removes what an earlier sync wrote, so a language dropped upstream goes too.
for (const entry of fs.readdirSync(appResources)) {
  if (entry.endsWith(".lproj")) fs.rmSync(path.join(appResources, entry), { recursive: true })
}

const languages = []
for (const lang of fs.readdirSync(i18n).sort()) {
  const file = path.join(i18n, lang, "shell.json")
  if (!fs.existsSync(file)) continue
  const flat = flatten(JSON.parse(fs.readFileSync(file, "utf8")))
  const extra = macStrings[lang] || {}
  const strings = []
  const plurals = []
  for (const [key, value] of Object.entries({ ...flat, ...extra }).sort()) {
    if (!wanted(key) && !(key in extra)) continue
    if (value === null || value === undefined || value === "") continue
    if (typeof value === "object") plurals.push([key, value])
    else strings.push(`"${escape(key)}" = "${escape(value)}";`)
  }
  if (strings.length === 0 && plurals.length === 0) continue

  const lproj = LPROJ[lang] || lang
  const dir = path.join(appResources, `${lproj}.lproj`)
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, "Localizable.strings"), strings.join("\n") + "\n")

  // Counted strings: "%1" becomes the count's "%d", the only number they carry.
  const dict = plurals.map(([key, forms]) => {
    const variants = Object.entries(forms)
      .map(([form, text]) => `\t\t\t<key>${xml(form)}</key>\n\t\t\t<string>${xml(String(text).replace("%1", "%d"))}</string>`)
      .join("\n")
    return `\t<key>${xml(key)}</key>\n\t<dict>\n\t\t<key>NSStringLocalizedFormatKey</key>\n\t\t<string>%#@count@</string>\n`
      + `\t\t<key>count</key>\n\t\t<dict>\n\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n`
      + `\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>d</string>\n${variants}\n\t\t</dict>\n\t</dict>`
  }).join("\n")
  fs.writeFileSync(path.join(dir, "Localizable.stringsdict"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n`
    + `<plist version="1.0">\n<dict>\n${dict}\n</dict>\n</plist>\n`)
  languages.push(lproj)
}

console.log(`synced data and ${languages.length} languages: ${languages.join(" ")}`)
