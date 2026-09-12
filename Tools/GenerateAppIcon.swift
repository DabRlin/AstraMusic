#!/usr/bin/env swift

// AstraMusic app-icon generator.
//
// Everything is drawn with SwiftUI and rasterised through `ImageRenderer`, so
// the icon is code: tweak a constant, re-run, done. This file lives outside the
// `AstraMusic/` source folder on purpose — anything inside that folder is
// auto-added to the app target (PBXFileSystemSynchronizedRootGroup), and a
// top-level script cannot share a target with the app.
//
//   swift Tools/GenerateAppIcon.swift preview
//       Render each concept to Tools/IconPreviews/<name>-{512,64,16}.png
//
//   swift Tools/GenerateAppIcon.swift install <concept>
//       Write the 10 macOS icon sizes into Assets.xcassets/AppIcon.appiconset
//       and regenerate its Contents.json.
//
//   swift Tools/GenerateAppIcon.swift list
//       Print the concept names.

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Apple's macOS icon grid

/// On a 1024×1024 canvas the continuous-corner rounded rectangle occupies
/// 824×824 (≈100 pt margin per side) with a ~185.4 pt corner radius.
enum IconGrid {
    static let insetRatio: CGFloat = 100.0 / 1024.0
    static let cornerRatio: CGFloat = 185.4 / 824.0
}

// MARK: - Palette

enum IconPalette {
    static let accentLight = Color(red: 0.63, green: 0.52, blue: 1.00)   // #A185FF
    static let accent = Color(red: 0.49, green: 0.36, blue: 1.00)        // #7D5CFF (Theme.accent)
    static let accentDeep = Color(red: 0.28, green: 0.13, blue: 0.72)    // #4721B8
    static let ink = Color(red: 0.24, green: 0.11, blue: 0.62)
}

// MARK: - Concepts

enum IconConcept: String, CaseIterable {
    case sparkleNote
    case waveform
    case vinylStar

    var title: String {
        switch self {
        case .sparkleNote: "Sparkle Note"
        case .waveform: "Waveform"
        case .vinylStar: "Vinyl Star"
        }
    }
}

// MARK: - Shapes

/// Four-pointed concave "sparkle" — the Astra motif.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        let k: CGFloat = 0.28
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y),
                       control: CGPoint(x: c.x + rx * k, y: c.y - ry * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY),
                       control: CGPoint(x: c.x + rx * k, y: c.y + ry * k))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y),
                       control: CGPoint(x: c.x - rx * k, y: c.y + ry * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY),
                       control: CGPoint(x: c.x - rx * k, y: c.y - ry * k))
        p.closeSubpath()
        return p
    }
}

/// A single quarter note (♩): tilted head and a straight stem. Deliberately
/// flag-less — in `sparkleNote` the sparkle takes the flag's place.
struct QuarterNoteShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()

        let rx = 0.34 * w
        let ry = 0.24 * h
        var head = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
        head = head.applying(CGAffineTransform(rotationAngle: -20 * .pi / 180))
        head = head.applying(CGAffineTransform(translationX: 0.34 * w, y: 0.76 * h))
        p.addPath(head)

        p.addRoundedRect(
            in: CGRect(x: 0.56 * w, y: 0.02 * h, width: 0.14 * w, height: 0.76 * h),
            cornerSize: CGSize(width: 0.07 * w, height: 0.07 * h)
        )

        return p
    }
}

// MARK: - The icon

struct IconCanvas: View {
    let concept: IconConcept
    let size: CGFloat

    private var side: CGFloat { size * (1 - 2 * IconGrid.insetRatio) }
    private var cornerRadius: CGFloat { side * IconGrid.cornerRatio }

    var body: some View {
        ZStack {
            squircle
            mark
        }
        .frame(width: size, height: size, alignment: .center)
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [IconPalette.accentLight, IconPalette.accent, IconPalette.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.34), Color.white.opacity(0)],
                            center: UnitPoint(x: 0.26, y: 0.14),
                            startRadius: 0,
                            endRadius: side * 0.95
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: max(1, size * 0.005))
            )
            .frame(width: side, height: side)
            .shadow(color: Color.black.opacity(0.30), radius: size * 0.022, y: size * 0.014)
    }

    @ViewBuilder
    private var mark: some View {
        switch concept {
        case .sparkleNote:
            ZStack {
                QuarterNoteShape()
                    .fill(Color.white)
                    .frame(width: side * 0.36, height: side * 0.58)
                    .offset(x: -side * 0.08, y: side * 0.05)
                SparkleShape()
                    .fill(Color.white)
                    .frame(width: side * 0.18, height: side * 0.18)
                    .offset(x: side * 0.18, y: -side * 0.20)
            }

        case .waveform:
            ZStack {
                HStack(alignment: .center, spacing: side * 0.052) {
                    ForEach(Array([0.22, 0.40, 0.66, 0.40, 0.22].enumerated()), id: \.offset) { _, value in
                        Capsule()
                            .fill(Color.white)
                            .frame(width: side * 0.088, height: side * value)
                    }
                }
                SparkleShape()
                    .fill(Color.white)
                    .frame(width: side * 0.15, height: side * 0.15)
                    .offset(x: side * 0.27, y: -side * 0.27)
            }

        case .vinylStar:
            ZStack {
                Circle()
                    .fill(Color.white)
                Circle()
                    .strokeBorder(IconPalette.ink.opacity(0.16), lineWidth: side * 0.010)
                    .padding(side * 0.055)
                Circle()
                    .strokeBorder(IconPalette.ink.opacity(0.16), lineWidth: side * 0.010)
                    .padding(side * 0.105)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [IconPalette.accentLight, IconPalette.accentDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: side * 0.22, height: side * 0.22)
                SparkleShape()
                    .fill(Color.white)
                    .frame(width: side * 0.13, height: side * 0.13)
            }
            .frame(width: side * 0.62, height: side * 0.62)
        }
    }
}

// MARK: - Rasterising

struct GenError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

@MainActor
func render(_ concept: IconConcept, pixels: Int) throws -> CGImage {
    let size = CGFloat(pixels)
    let renderer = ImageRenderer(content: IconCanvas(concept: concept, size: size))
    renderer.scale = 1
    guard let image = renderer.cgImage else {
        throw GenError("ImageRenderer produced no image for \(concept.rawValue) @\(pixels)px")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw GenError("cannot create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw GenError("cannot write \(url.path)")
    }
}

// MARK: - macOS icon set

/// (point size, scale, pixel dimension) — mirrors the empty appiconset Xcode ships.
let iconSpecs: [(size: String, scale: String, pixels: Int)] = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]

func iconFilename(size: String, scale: String) -> String {
    scale == "2x" ? "icon_\(size)@2x.png" : "icon_\(size).png"
}

func contentsJSON() throws -> Data {
    let images: [[String: Any]] = iconSpecs.map { spec in
        [
            "filename": iconFilename(size: spec.size, scale: spec.scale),
            "idiom": "mac",
            "scale": spec.scale,
            "size": spec.size,
        ]
    }
    let root: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ]
    var data = try JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys]
    )
    data.append(0x0A)
    return data
}

// MARK: - Paths

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tools/
    .deletingLastPathComponent()  // repository root
let previewsDirectory = repoRoot.appendingPathComponent("Tools/IconPreviews")
let iconSetDirectory = repoRoot
    .appendingPathComponent("AstraMusic/Assets.xcassets/AppIcon.appiconset")

// MARK: - Commands

@MainActor
func run(_ arguments: [String]) throws {
    let command = arguments.first ?? "list"
    switch command {
    case "list":
        for concept in IconConcept.allCases {
            print("\(concept.rawValue)  —  \(concept.title)")
        }

    case "preview":
        for concept in IconConcept.allCases {
            for pixels in [512, 64, 16] {
                let image = try render(concept, pixels: pixels)
                let url = previewsDirectory
                    .appendingPathComponent("\(concept.rawValue)-\(pixels).png")
                try writePNG(image, to: url)
                print("wrote \(url.path)")
            }
        }

    case "install":
        guard let raw = arguments.dropFirst().first,
              let concept = IconConcept(rawValue: raw) else {
            throw GenError("usage: install <concept>; concepts: \(IconConcept.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        for spec in iconSpecs {
            let image = try render(concept, pixels: spec.pixels)
            let url = iconSetDirectory
                .appendingPathComponent(iconFilename(size: spec.size, scale: spec.scale))
            try writePNG(image, to: url)
        }
        let contentsURL = iconSetDirectory.appendingPathComponent("Contents.json")
        try contentsJSON().write(to: contentsURL)
        print("installed \(concept.rawValue) into \(iconSetDirectory.path)")

    default:
        throw GenError("unknown command '\(command)' — expected list, preview, or install")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
MainActor.assumeIsolated {
    do {
        try run(arguments)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
