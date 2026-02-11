# HomeSlice

A kawaii desktop companion app for macOS. Features an adorable animated pizza (or other companions) that lives on your screen, responds to interactions, and can chat with you.

## Features

- **Multiple Companions**: Choose between Pizza, Business Pizza, or Cat
- **Mood System**: Happy, Excited, Sleepy, Love, and Surprised moods with expressive animations
- **Chat Integration**: Talk to your companion with AI-powered responses
- **Particle Effects**: Hearts, stars, confetti, and sparkle animations
- **Draggable**: Move your companion anywhere on screen
- **Menu Bar Controls**: Quick access to settings and companion options
- **Customizable Hotkey**: Set a global hotkey to toggle visibility

## Building

```bash
swiftc -o HomeSlice HomeSlice.swift -framework AppKit -framework SwiftUI -framework Carbon
```

## Running

```bash
./HomeSlice
```

## Companions

| Companion | Description |
|-----------|-------------|
| Pizza | Classic kawaii pizza slice with pepperoni cheeks |
| Business Pizza | Professional pizza with glasses, slicked crust, and a green pepper tie |
| Cat | Adorable kawaii cat |

## Controls

- **Click**: Interact with your companion
- **Drag**: Move companion around the screen
- **Right-click**: Open context menu
- **Menu Bar**: Access settings, change mood, switch companions
