# Multitrack Timeline

A real-time multitrack timeline application for sending triggers and continuous values to Pure Data (Pd).

## Features

- Create and manipulate points across multiple tracks
- Interpolate values between points
- Connect points to create segments
- Synchronize musical events with a playhead controlled by BPM
- Send track values to Pure Data in real-time
- Save and load timeline configurations

## Requirements

- Tcl/Tk
- Pure Data (Pd)

## Usage

1. Run the script using Tcl:

```bash
tclsh timeline.tcl
```

2. Use the interface to add, move, and connect points on the timeline.
3. Adjust the BPM to control playback speed.
4. Play/pause the timeline to send values to Pure Data.

## Controls

- **Left-click**: Add a point
- **Left-click and drag**: Move a point
- **Middle-click**: Connect two points
- **Right-click**: Remove a point

## Configuration

- **Tracks**: 4 (default)
- **Timeline width**: 1000 pixels
- **Track height**: 100 pixels

## Communication with Pure Data

The application sends track values to Pure Data on port 3000. Ensure Pure Data is running and listening on this port.

## Author

Martin Jaros (jarosmartin@duck.com)

## License

GNU General Public License (GPL) v3


