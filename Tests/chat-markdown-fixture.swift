import Foundation

/// A long reply in every block shape the chat draws, shared by the markdown harness and benchmark.
enum ChatMarkdownFixture {
    static func longReply(sections: Int = 10) -> String {
        (1...sections).map(section).joined(separator: "\n\n")
    }

    /// Streamed in `size`-character pieces, as `AIChatState` flushes them every 40 ms.
    static func chunks(of text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return pieces
    }

    private static func section(_ number: Int) -> String {
        let language = ["swift", "python", "json", "rust", "typescript"][number % 5]
        return """
            ## Part \(number): the apple orchard

            The orchard holds **\(number * 12) trees** in *\(number + 2) rows*, and each row is \
            watered by `drip line \(number)`. See [the survey](https://example.com/orchard/\(number)) \
            for the full map. The yield follows $y = a x^2 + b x + c$ with \\(a = \(number)\\), so \
            doubling the rows does not double the crop, and ~~nobody~~ everybody checks it twice.

            A second paragraph runs a little longer, so the wrap has work to do: the pickers start at \
            dawn, the crates go out at noon and the cider press runs until the light goes, which in \
            row \(number) is a long day, and every apple is weighed before it leaves the orchard.

            - Pick the low branches first
            - Sort by size, then by colour
              - Bruised fruit goes to the press
              - The rest goes to market
            - [ ] Count the crates in row \(number)
            - [x] Oil the ladder

            ```\(language)
            \(code(language, number))
            ```

            The roots of the yield curve are

            $$\\frac{-b \\pm \\sqrt{b^2 - 4 a c}}{2 a}$$

            and the season's total is $$\\sum_{i=1}^{n} y_i$$ when no row is skipped.

            1. Weigh the crates
            2. Log the weight against row \(number)
            3. Ship the crates before \(number + 3) pm

            | Row | Trees | Yield |
            | :-- | :-: | --: |
            | \(number) | \(number * 12) | \(number * 340) kg |
            | \(number + 1) | \(number * 11) | \(number * 310) kg |
            | \(number + 2) | \(number * 10) | \(number * 290) kg |

            > The best apple in row \(number) is the one nobody has picked yet.

            ---
            """
    }

    private static func code(_ language: String, _ number: Int) -> String {
        switch language {
        case "swift":
            """
            struct Row\(number): Sendable {
                let trees: Int
                var yield: Double = 0 // kilograms
                func crates(of size: Double = 18.5) -> Int {
                    Int((yield / size).rounded(.up))
                }
            }
            let rows = (1...\(number)).map { Row\(number)(trees: $0 * 12) }
            print("Rows: \\(rows.count)", rows.map(\\.trees).reduce(0, +))
            """
        case "python":
            """
            def crates(row: int, size: float = 18.5) -> int:
                \"\"\"Crates needed for one row.\"\"\"
                yield_kg = row * 340  # measured
                return -(-yield_kg // size)

            for row in range(1, \(number + 1)):
                print(f"row {row}: {crates(row)} crates")
            """
        case "json":
            """
            {
              "row": \(number),
              "trees": \(number * 12),
              "yield": { "kg": \(number * 340), "graded": true },
              "pickers": ["Ana", "Ben", "Chloe"],
              "notes": null
            }
            """
        case "rust":
            """
            fn crates(row: u32, size: f64) -> u32 {
                let yield_kg = f64::from(row) * 340.0; // measured
                (yield_kg / size).ceil() as u32
            }

            fn main() {
                for row in 1..=\(number) { println!("row {row}: {}", crates(row, 18.5)); }
            }
            """
        default:
            """
            interface Row { trees: number; yield: number }
            const rows: Row[] = Array.from({ length: \(number) }, (_, i) => ({
              trees: (i + 1) * 12,
              yield: (i + 1) * 340,
            }));
            export const total = rows.reduce((sum, row) => sum + row.yield, 0); // kg
            console.log(`total ${total} kg`);
            """
        }
    }
}
