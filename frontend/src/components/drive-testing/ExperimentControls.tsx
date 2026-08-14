import React from 'react'
import { button, buttonRow, notice, section, sectionTitle } from './styles'

interface Props {
  canStart: boolean
  state: string
  pauseSupported: boolean
  hasExperiment: boolean
  onValidate: () => void
  onStart: () => void
  onPause: () => void
  onResume: () => void
  onStop: () => void
  onEmergency: () => void
  onRepeat: () => void
  onQuickTest: () => void
  onAddQueue: () => void
  onRunQueue: () => void
}

export default function ExperimentControls(props: Props) {
  const running = props.state === 'running'
  const paused = props.state === 'paused'
  const active = ['starting', 'running', 'paused', 'stopping'].includes(props.state)
  return <section style={section}>
    <div style={sectionTitle}>Experiment Controls</div>
    {!props.canStart && !active && <div style={{ ...notice('warning'), marginBottom: 10 }}>Start Test requires enabled flags, a reachable and ready device, a valid route and profile, and no active stable drive or experiment.</div>}
    <div style={buttonRow}>
      <button style={button()} onClick={props.onValidate}>Validate Test</button>
      <button style={button('primary')} disabled={!props.canStart || active} onClick={props.onStart}>Start Test</button>
      <button style={button()} disabled={!running || !props.pauseSupported} onClick={props.onPause}>Pause Test</button>
      <button style={button()} disabled={!paused} onClick={props.onResume}>Resume Test</button>
      <button style={button()} disabled={!active} onClick={props.onStop}>Stop Test</button>
      <button style={button('danger')} disabled={!active} onClick={props.onEmergency}>Emergency Stop and Reset GPS</button>
      <button style={button()} disabled={!props.hasExperiment || active} onClick={props.onRepeat}>Run Again</button>
      <button style={button()} disabled={!props.hasExperiment} onClick={props.onAddQueue}>Add to Queue</button>
      <button style={button()} onClick={props.onRunQueue}>Run Selected Queue</button>
      <button style={button('primary')} disabled={active} onClick={props.onQuickTest}>Run Quick Test</button>
    </div>
  </section>
}
