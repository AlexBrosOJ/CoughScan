import Foundation

nonisolated enum ExcelReport {
    private enum Cell {
        case text(String), integer(Int)

        var xml: String {
            switch self {
            case .text(let value):
                let valid = value.unicodeScalars.filter {
                    $0 == "\t" || $0 == "\n" || $0 == "\r" || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF)
                }
                let escaped = String(String.UnicodeScalarView(valid))
                    .replacingOccurrences(of: "_(?=x[0-9a-fA-F]{4}_)", with: "_x005F_", options: .regularExpression)
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\r", with: "&#13;")
                return #"<c t="inlineStr"><is><t xml:space="preserve">"# + escaped + "</t></is></c>"
            case .integer(let value):
                return "<c><v>\(value)</v></c>"
            }
        }
    }

    static func data(stats: PeriodStatistics, patient: PatientInfo) -> Data {
        let daily: [[Cell]] = stats.dailyStats.reversed().map { day in
            [.text(day.dateString), .integer(day.totalRecordings), .integer(day.totalCoughs),
             .integer(day.monitoringSeconds), .text(day.getPeakHour().0)]
        }
        let hourly: [[Cell]] = (0..<24).map { hour in
            [.text(String(format: "%02d:00", hour)), .integer(stats.hourlyCoughs[hour] ?? 0)]
        }
        let results: [(name: String, widths: [Int], rows: [[Cell]])] = [
            ("Сводка", [32, 48], [
                [.text("ФИО"), .text(patient.fullName)],
                [.text("Начало"), .text(stats.startDate)],
                [.text("Конец"), .text(stats.endDate)],
                [.text("Фрагментов"), .integer(stats.totalRecordings)],
                [.text("Кашлей"), .integer(stats.totalCoughs)],
                [.text("Мониторинг, сек"), .integer(stats.totalMonitoringSeconds)],
                [.text("Средняя оценка модели, %"), .integer(Int(stats.avgProbability * 100))],
                [.text("Примечание"), .text(patient.notes)]
            ]),
            ("По дням", [16, 16, 14, 22, 16], [
                [.text("Дата"), .text("Фрагментов"), .text("Кашлей"), .text("Мониторинг, сек"), .text("Пиковый час")]
            ] + daily),
            ("По часам", [16, 14], [[.text("Время"), .text("Кашлей")]] + hourly)
        ]
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parent = "http://schemas.openxmlformats.org/package/2006"
        let sheetNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        var archive = StoredZIP()
        let sheets = results.enumerated().map { i, sheet in
            #"<sheet name="\#(sheet.name)" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
        }.joined()
        archive.add("xl/workbook.xml", #"<workbook xmlns="\#(sheetNS)" xmlns:r="\#(office)"><sheets>\#(sheets)</sheets></workbook>"#)
        archive.add("_rels/.rels", #"<Relationships xmlns="\#(parent)/relationships"><Relationship Id="rId1" Type="\#(office)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        var workbookRels = ""
        var contentTypes = #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
        for (index, result) in results.enumerated() {
            let number = index + 1
            let target = "worksheets/sheet\(number).xml"
            workbookRels += #"<Relationship Id="rId\#(number)" Type="\#(office)/worksheet" Target="\#(target)"/>"#
            contentTypes += #"<Override PartName="/xl/\#(target)" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            let columns = result.widths.enumerated().map { i, width in
                #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(width)" customWidth="1"/>"#
            }.joined()
            let rows = result.rows.map { row in "<row>" + row.map(\.xml).joined() + "</row>" }.joined()
            archive.add("xl/\(target)", #"<worksheet xmlns="\#(sheetNS)"><cols>\#(columns)</cols><sheetData>\#(rows)</sheetData></worksheet>"#)
        }
        archive.add("xl/_rels/workbook.xml.rels", #"<Relationships xmlns="\#(parent)/relationships">\#(workbookRels)</Relationships>"#)
        archive.add("[Content_Types].xml", #"<Types xmlns="\#(parent)/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\#(contentTypes)</Types>"#)
        return archive.finish()
    }
}

// XLSX is a ZIP package. Reports are small, so use the standard stored method.
private nonisolated struct StoredZIP {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ xml: String) {
        let filename = Data(name.utf8)
        let contents = Data(xml.utf8)
        let offset = UInt32(body.count)
        let size = UInt32(contents.count)
        var crc: UInt32 = .max
        for byte in contents {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
            }
        }
        var header = Data()
        for field: UInt16 in [20, 0, 0, 0, 0x21] { header.putLE(field) }
        for field: UInt32 in [~crc, size, size] { header.putLE(field) }
        header.putLE(UInt16(filename.count))
        header.putLE(UInt16(0))

        body.putLE(UInt32(0x04034B50))
        body.append(header)
        body.append(filename)
        body.append(contents)

        directory.putLE(UInt32(0x02014B50))
        directory.putLE(UInt16(20))
        directory.append(header)
        for _ in 0..<3 { directory.putLE(UInt16(0)) }
        directory.putLE(UInt32(0))
        directory.putLE(offset)
        directory.append(filename)
        count += 1
    }

    mutating func finish() -> Data {
        let offset = UInt32(body.count)
        body.append(directory)
        body.putLE(UInt32(0x06054B50))
        for field: UInt16 in [0, 0, count, count] { body.putLE(field) }
        body.putLE(UInt32(directory.count))
        body.putLE(offset)
        body.putLE(UInt16(0))
        return body
    }
}

private extension Data {
    nonisolated mutating func putLE<T: FixedWidthInteger>(_ input: T) {
        var value = input.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
