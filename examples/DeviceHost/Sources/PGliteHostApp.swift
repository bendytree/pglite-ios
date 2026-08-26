import SwiftUI
import PGliteKit

@main
struct PGliteHostApp: App {
    @State private var status = "booting…"

    var body: some Scene {
        WindowGroup {
            Text(status)
                .padding()
                .task {
                    do {
                        let root = FileManager.default.temporaryDirectory
                            .appendingPathComponent("pglite-host-\(UUID().uuidString)")
                        let db = try PGliteDatabase(root: root)
                        let r = try await db.execute("SELECT version()")
                        status = r.rows[0].text(0) ?? "no row"
                        await db.close()
                    } catch {
                        status = "FAILED: \(error)"
                    }
                }
        }
    }
}
