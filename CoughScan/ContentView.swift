import SwiftUI
import AVFoundation
import UIKit
import Charts

func formatTime(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%dч%02dм", h, m) }
    if m > 0 { return String(format: "%dм%02dс", m, s) }
    return "\(s)с"
}

struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            MonitoringScreen().tabItem { Label("Мониторинг", systemImage: "mic.fill") }.tag(0)
            AnalysisScreen().tabItem { Label("Анализ", systemImage: "chart.bar.fill") }.tag(1)
            CalendarScreen().tabItem { Label("Календарь", systemImage: "calendar") }.tag(2)
            PatientScreen().tabItem { Label("Пациент", systemImage: "person.fill") }.tag(3)
        }
        .preferredColorScheme(.dark)
    }
}

// =================== МОНИТОРИНГ ===================
struct MonitoringScreen: View {
    @StateObject private var monitoring = MonitoringManager.shared
    @State private var todayStats = CoughStorage.shared.getTodayStats()
    @State private var showPermissionAlert = false
    @State private var showUploadConsent = false
    @AppStorage("audio_upload_consent") private var uploadConsent = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("📊 Сегодня").font(.headline)
                            Spacer()
                            Text(Date().formatted(date: .numeric, time: .omitted))
                                .font(.caption).foregroundColor(.gray)
                        }
                        
                        HStack {
                            StatView(value: "\(todayStats.totalRecordings)", label: "Записей", color: .blue)
                            StatView(value: "\(todayStats.totalCoughs)", label: "Кашлей", color: .red)
                            StatView(value: formatTime(monitoring.monitoringTime), label: "Мониторинг", color: .orange)
                        }
                        
                        if monitoring.pendingQueueSize > 0 {
                            Text("Ожидают отправки: \(monitoring.pendingQueueSize) файлов")
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.12))
                    .cornerRadius(16)
                    
                    VStack(spacing: 16) {
                        Circle()
                            .fill(monitoring.isMonitoring ? Color.red : Color.gray)
                            .frame(width: 60, height: 60)
                            .overlay(Text(monitoring.isMonitoring ? "🔴" : "⚫").font(.largeTitle))
                        
                        Text(monitoring.isMonitoring ? "Мониторинг активен" : "Остановлен")
                            .font(.headline)
                            .foregroundColor(monitoring.isMonitoring ? .green : .gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(white: 0.12))
                    .cornerRadius(16)
                    
                    Text("При мониторинге звук записывается и отправляется на сервер для определения кашля. Результаты не являются диагнозом.")
                        .font(.caption).foregroundColor(.gray)
                    if let error = monitoring.errorMessage {
                        Text(error).font(.caption).foregroundColor(.orange)
                    }
                    Button {
                        if monitoring.isMonitoring {
                            monitoring.stop()
                        } else {
                            if uploadConsent { requestMicrophone() }
                            else { showUploadConsent = true }
                        }
                    } label: {
                        Text(monitoring.isMonitoring ? "ОСТАНОВИТЬ" : "ЗАПУСТИТЬ")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(monitoring.isMonitoring ? Color.red : Color.green)
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Мониторинг")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: CoughStorage.didChange)) { _ in
                todayStats = CoughStorage.shared.getTodayStats()
            }
            .alert("Отправка аудио", isPresented: $showUploadConsent) {
                Button("Отмена", role: .cancel) {}
                Button("Согласен, начать") { uploadConsent = true; requestMicrophone() }
            } message: {
                Text("Во время мониторинга записывается окружающий звук, включая возможную речь. Аудио отправляется на alexbrosoj-yam-134b.twc1.net по HTTP без шифрования. После успешного анализа локальные фрагменты удаляются; при ошибке остаются в очереди. Данные на сервере этой кнопкой не удаляются.")
            }
            .alert("Нужно разрешение на микрофон", isPresented: $showPermissionAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }
    private func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { monitoring.start() }
                else { showPermissionAlert = true }
            }
        }
    }
}

struct StatView: View {
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack {
            Text(value).font(.title2).bold().foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

// =================== АНАЛИЗ ===================
struct AnalysisScreen: View {
    @State private var periodStats: PeriodStatistics?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if let s = periodStats {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("📊 Последние 7 дней").font(.headline)
                            
                            HStack {
                                StatView(value: "\(s.totalRecordings)", label: "Записей", color: .blue)
                                StatView(value: "\(s.totalCoughs)", label: "Кашлей", color: .red)
                            }
                            
                            HStack {
                                StatView(value: "\(Int(s.avgProbability * 100))%", label: "Вероятность", color: .orange)
                                StatView(value: s.monitoringTimeFormatted, label: "Мониторинг", color: .purple)
                            }
                        }
                        .padding()
                        .background(Color(white: 0.12))
                        .cornerRadius(16)
                        
                        Button(action: exportCSV) {
                            Text("📤 Экспорт в CSV")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.horizontal)
                    } else {
                        Text("Нет данных").foregroundColor(.gray)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Анализ")
            .onReceive(NotificationCenter.default.publisher(for: CoughStorage.didChange)) { _ in refreshStats() }
            .onAppear {
                let today = CoughStorage.currentDateCode()
                periodStats = CoughStorage.shared.getPeriodStats(startDateCode: CoughStorage.dateCode(from: Int64((Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()).timeIntervalSince1970 * 1000)), endDateCode: today)
            }
        }
    }
    
    private func refreshStats() {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        periodStats = CoughStorage.shared.getPeriodStats(
            startDateCode: CoughStorage.dateCode(from: Int64(start.timeIntervalSince1970 * 1000)),
            endDateCode: CoughStorage.currentDateCode())
    }

    func exportCSV() {
        guard let stats = periodStats else { return }
        let patient = CoughStorage.shared.patientInfo
        let csvString = stats.toCSV(patient: patient)
        
        let fileName = "Кашель_\(UUID().uuidString).csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            try csvString.write(to: path, atomically: true, encoding: .utf8)
            let activityVC = UIActivityViewController(activityItems: [path], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                activityVC.popoverPresentationController?.sourceView = rootVC.view
                activityVC.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 1, height: 1)
                activityVC.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: path) }
                rootVC.present(activityVC, animated: true)
            }
        } catch {
            print("Ошибка экспорта: \(error)")
        }
    }
}

// =================== ПАЦИЕНТ ===================
struct PatientScreen: View {
    @State private var patient: PatientInfo = CoughStorage.shared.patientInfo
    @State private var saved = false
    @State private var showClearAlert = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Фамилия", text: $patient.lastName).textFieldStyle(.roundedBorder)
                        TextField("Имя", text: $patient.firstName).textFieldStyle(.roundedBorder)
                        TextField("Отчество", text: $patient.middleName).textFieldStyle(.roundedBorder)
                        TextField("Примечание", text: $patient.notes).textFieldStyle(.roundedBorder)
                        
                        Button {
                            CoughStorage.shared.patientInfo = patient
                            saved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                        } label: {
                            Text("💾 Сохранить").foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 44)
                                .background(Color.green).cornerRadius(8)
                        }
                        
                        if saved {
                            Text("✅ Сохранено").foregroundColor(.green).font(.caption)
                        }
                    }
                    .padding().background(Color(white: 0.12)).cornerRadius(16)
                    
                    Button(action: { showClearAlert = true }) {
                        Text("🗑 Очистить все данные")
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Color.red).foregroundColor(.white).cornerRadius(8)
                    }
                    .padding(.horizontal)
                    .alert("Вы уверены?", isPresented: $showClearAlert) {
                        Button("Отмена", role: .cancel) {}
                        Button("Удалить", role: .destructive) {
                            MonitoringManager.shared.clearAllData()
                            UserDefaults.standard.set(false, forKey: "audio_upload_consent")
                            patient = PatientInfo()
                        }
                    } message: {
                        Text("Это безвозвратно удалит всю статистику, историю и очередь.")
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Пациент")
        }
    }
}

// =================== КАЛЕНДАРЬ (ИСПРАВЛЕННЫЙ) ===================
struct CalendarScreen: View {
    @State private var currentMonth = Date()
    @State private var selectedDateCode = CoughStorage.currentDateCode()
    @State private var monthSummary: [Int: Int] = [:]
    @State private var dailyStats: DailyStatistics?
    
    private let calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Понедельник
        return cal
    }()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Навигация по месяцам
                    HStack {
                        Button(action: { changeMonth(-1) }) { Image(systemName: "chevron.left").padding() }
                        Spacer()
                        Text(currentMonth.formatted(.dateTime.month(.wide).year())).font(.headline)
                        Spacer()
                        Button(action: { changeMonth(1) }) { Image(systemName: "chevron.right").padding() }
                    }
                    .padding(.horizontal)
                    
                    // Дни недели
                    HStack {
                        ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { day in
                            Text(day).font(.caption).bold().frame(maxWidth: .infinity).foregroundColor(.gray)
                        }
                    }
                    
                    // Сетка календаря (ОБЫЧНЫЙ VStack + HStack)
                    VStack(spacing: 8) {
                        let days = buildDaysArray()
                        
                        ForEach(0..<days.count/7, id: \.self) { rowIndex in
                            HStack(spacing: 8) {
                                ForEach(0..<7, id: \.self) { colIndex in
                                    let index = rowIndex * 7 + colIndex
                                    if index < days.count {
                                        let day = days[index]
                                        if let day = day {
                                            let dateCode = getDateCode(for: day)
                                            let coughs = monthSummary[day] ?? 0
                                            let isSelected = dateCode == selectedDateCode
                                            let isToday = dateCode == CoughStorage.currentDateCode()
                                            
                                            VStack(spacing: 2) {
                                                Text("\(day)")
                                                    .font(.system(size: 16, weight: isToday ? .bold : .regular))
                                                    .foregroundColor(isSelected ? .white : (isToday ? .blue : .primary))
                                                if coughs > 0 {
                                                    Text("\(coughs)").font(.system(size: 9)).foregroundColor(.red).bold()
                                                } else {
                                                    Text(" ").font(.system(size: 9))
                                                }
                                            }
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 40)
                                            .background(isSelected ? Color.blue : (isToday ? Color.blue.opacity(0.1) : Color.clear))
                                            .cornerRadius(8)
                                            .onTapGesture {
                                                selectedDateCode = dateCode
                                                dailyStats = CoughStorage.shared.getDailyStats(dateCode: dateCode)
                                            }
                                        } else {
                                            Text("").frame(maxWidth: .infinity).frame(height: 40)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    Divider()
                    
                    if let stats = dailyStats {
                        DailyDetailsView(stats: stats)
                    } else {
                        Text("Выберите день").foregroundColor(.gray)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.black)
            .navigationTitle("📅 Календарь")
            .onAppear { updateData() }
            .onReceive(NotificationCenter.default.publisher(for: CoughStorage.didChange)) { _ in updateData() }
        }
    }
    
    func updateData() {
        let comps = calendar.dateComponents([.year, .month], from: currentMonth)
        monthSummary = CoughStorage.shared.getMonthSummary(year: comps.year ?? 2024, month: comps.month ?? 1)
        dailyStats = CoughStorage.shared.getDailyStats(dateCode: selectedDateCode)
    }
    
    func changeMonth(_ offset: Int) {
        currentMonth = calendar.date(byAdding: .month, value: offset, to: currentMonth) ?? currentMonth
        updateData()
    }
    
    // --- ПРАВИЛЬНЫЙ РАСЧЕТ ДНЕЙ ---
    func buildDaysArray() -> [Int?] {
        let range = calendar.range(of: .day, in: .month, for: currentMonth)
        let daysInMonth = range?.count ?? 30
        let offset = getFirstDayOffset()
        
        var days: [Int?] = Array(repeating: nil, count: offset)
        for day in 1...daysInMonth {
            days.append(day)
        }
        
        // Добиваем до полной недели (7 ячеек)
        while days.count % 7 != 0 {
            days.append(nil)
        }
        
        return days
    }
    
    func getFirstDayOffset() -> Int {
        let comps = calendar.dateComponents([.year, .month], from: currentMonth)
        guard let firstOfMonth = calendar.date(from: DateComponents(
            year: comps.year,
            month: comps.month,
            day: 1,
            hour: 12
        )) else { return 0 }
        
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        // Пн=0, Вс=6
        return (weekday + 5) % 7
    }
    
    func getDateCode(for day: Int) -> Int {
        let comps = calendar.dateComponents([.year, .month], from: currentMonth)
        return (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + day
    }
}

struct DailyDetailsView: View {
    let stats: DailyStatistics
    @State private var showDetails = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📊 \(stats.dateString)").font(.headline)
                Spacer()
                if stats.totalCoughs > 0 {
                    Button(showDetails ? "Скрыть" : "График") {
                        withAnimation { showDetails.toggle() }
                    }
                    .font(.caption)
                }
            }
            
            if stats.hasData {
                HStack {
                    StatView(value: "\(stats.totalRecordings)", label: "Записей", color: .blue)
                    StatView(value: "\(stats.totalCoughs)", label: "Кашлей", color: .red)
                    StatView(value: "\(Int(stats.avgProbability * 100))%", label: "Вероятность", color: .orange)
                }
                
                Text("⏱ Мониторинг: \(stats.monitoringTimeFormatted)")
                    .font(.subheadline).foregroundColor(.gray)
                
                if stats.totalCoughs > 0 {
                    Text("📈 Кашлей: \(stats.getCoughsPerHourDisplay())")
                        .font(.subheadline)
                }
                
                if showDetails {
                    Divider().padding(.vertical, 8)
                    HourlyChartView(hourlyCoughs: stats.hourlyCoughs)
                }
            } else {
                Text("Нет данных за этот день").foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color(white: 0.12))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// =================== ГРАФИК (SWIFT CHARTS) ===================
struct HourlyChartView: View {
    let hourlyCoughs: [Int]
    
    var chartData: [(hour: String, count: Int)] {
        (0..<24).map { hour in
            (String(format: "%02d", hour), hourlyCoughs[hour])
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Кашель по часам").font(.subheadline).bold()
            
            Chart(chartData, id: \.hour) { item in
                BarMark(
                    x: .value("Час", item.hour),
                    y: .value("Кашлей", item.count)
                )
                .foregroundStyle(Color.red.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.gray.opacity(0.3))
                    AxisValueLabel().foregroundStyle(Color.gray)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.gray.opacity(0.3))
                    AxisValueLabel().foregroundStyle(Color.gray)
                }
            }
            .frame(height: 150)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MonitoringManager.shared)
} 
