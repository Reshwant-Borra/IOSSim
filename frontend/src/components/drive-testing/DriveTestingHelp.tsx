import React from 'react'
import { notice, section, sectionTitle } from './styles'

export default function DriveTestingHelp() {
  return <>
    <section style={section}><div style={sectionTitle}>Drive Testing Lab Limits</div><div style={notice('warning')}>Results are observations, not guarantees of third-party classification. Use only authorized devices and test accounts.</div><ul style={{ margin: '12px 0 0 18px', lineHeight: 1.7, fontSize: 13 }}><li>The computer sends coordinate sequences through the existing pymobiledevice3 DVT path.</li><li>Nothing is installed on the iPhone.</li><li>Static DVT commands contain latitude and longitude only.</li><li>GPX timestamps pace host-side playback and do not inject CLLocation.speed.</li><li>IOSSim cannot control or read Core Motion, accelerometer, gyroscope, Arity confidence, or third-party internal trip state.</li><li>External outcomes must be checked and entered manually.</li></ul></section>
    <section style={section}><div style={sectionTitle}>Output Folder</div><p style={{ fontSize: 13, lineHeight: 1.6 }}>Experiment files are stored under <code>backend/data/drive_testing/experiments/EXP-...</code>. Open that folder with Finder on macOS or File Explorer on Windows. Routes, logs, reports, and observations remain local and are excluded from Git.</p></section>
    <section style={section}><div style={sectionTitle}>Documentation</div><p style={{ fontSize: 13, lineHeight: 1.6 }}>See <code>docs/drive_testing/README.md</code> for launch, Quick Test, profiles, GPX comparison, queue, metrics, results, exports, test matrix, interpretation, troubleshooting, and safety guidance.</p></section>
  </>
}
