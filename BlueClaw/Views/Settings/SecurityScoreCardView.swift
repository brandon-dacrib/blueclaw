import SwiftUI

struct SecurityScoreCardView: View {
    let report: AuditReport

    var body: some View {
        VStack(spacing: 12) {
            // Circular score
            ZStack {
                Circle()
                    .stroke(AppColors.surfaceBorder, lineWidth: 8)
                    .frame(width: 100, height: 100)

                Circle()
                    .trim(from: 0, to: CGFloat(report.overallScore) / 100)
                    .stroke(report.scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(report.overallScore)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("/ 100")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textMuted)
                }
            }

            Text(report.scoreLabel)
                .font(.headline)
                .foregroundStyle(report.scoreColor)

            Text("\(report.findings.count) findings")
                .font(.caption)
                .foregroundStyle(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
