import UIKit
import AVFoundation
import Vision
import VisionKit

/// Live camera barcode scanner for a book's ISBN (EAN-13 on the back cover).
/// `multi`: keeps scanning book after book; «إنهاء» returns every code found, in order.
@available(iOS 16.0, *)
final class BarcodeScanner: NSObject, DataScannerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    var multi = false
    private var done: ((Any?) -> Void)?
    private weak var scannerVC: DataScannerViewController?
    private var codes: [String] = []
    private let counter = UILabel()
    private var finishButton: UIButton?

    func present(from presenter: UIViewController, done: @escaping (Any?) -> Void) {
        self.done = done
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted, DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                    self.finish(nil)
                    return
                }
                let vc = DataScannerViewController(
                    recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
                    qualityLevel: .balanced,
                    recognizesMultipleItems: false,
                    isHighFrameRateTrackingEnabled: false,
                    isPinchToZoomEnabled: true,
                    isGuidanceEnabled: true,
                    isHighlightingEnabled: true)
                vc.delegate = self
                // a run of scans can't be lost to a stray swipe: only «إلغاء» or «إنهاء» close it
                vc.isModalInPresentation = self.multi
                self.addChrome(to: vc)
                self.scannerVC = vc
                presenter.present(vc, animated: true) {
                    vc.presentationController?.delegate = self
                    try? vc.startScanning()
                }
            }
        }
    }

    private func addChrome(to vc: DataScannerViewController) {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "إلغاء".tr
        cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .capsule
        let close = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in self?.cancel() })

        let hint = UILabel()
        hint.text = multi ? "امسح باركود كتاب ورا كتاب، وفي الآخر اضغط «إنهاء»" : "وجّه الكاميرا على الباركود اللي خلف الكتاب"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        hint.layer.cornerRadius = 14
        hint.clipsToBounds = true

        let overlay = vc.overlayContainerView
        for v in [close, hint] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(v)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            hint.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
            hint.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        guard multi else {
            hint.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -24).isActive = true
            return
        }
        // the running count and «إنهاء», under the hint
        counter.text = "ما مسحت شي بعد".tr
        counter.textColor = .white
        counter.font = .systemFont(ofSize: 16, weight: .bold)
        counter.textAlignment = .center
        var fc = UIButton.Configuration.filled()
        fc.title = "إنهاء".tr
        fc.baseBackgroundColor = UIColor(red: 0.36, green: 0.76, blue: 0.68, alpha: 1)
        fc.baseForegroundColor = UIColor(red: 0.03, green: 0.13, blue: 0.11, alpha: 1)
        fc.cornerStyle = .capsule
        fc.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        let fin = UIButton(configuration: fc, primaryAction: UIAction { [weak self] _ in self?.complete() })
        fin.isEnabled = false
        finishButton = fin
        for v in [counter, fin] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(v)
        }
        NSLayoutConstraint.activate([
            fin.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            fin.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: fin.topAnchor, constant: -12),
            counter.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            counter.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: counter.topAnchor, constant: -12)
        ])
    }

    private func countText(_ n: Int) -> String {
        switch n {
        case 1: return "كتاب واحد"
        case 2: return "كتابان"
        case 3...10: return "\(n) كتب"
        default: return "\(n) كتابًا"
        }
    }

    private func complete() {
        scannerVC?.stopScanning()
        scannerVC?.dismiss(animated: true)
        finish(codes)
    }

    private func cancel() {
        scannerVC?.stopScanning()
        scannerVC?.dismiss(animated: true)
        finish(nil)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if multi, case .barcode(let code) = item, let value = code.payloadStringValue, !value.isEmpty {
                if codes.contains(value) { continue }
                codes.append(value)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                counter.text = "مسحت ".tr + countText(codes.count)
                finishButton?.isEnabled = true
                UIView.animate(withDuration: 0.12, animations: { self.counter.transform = CGAffineTransform(scaleX: 1.15, y: 1.15) }) { _ in
                    UIView.animate(withDuration: 0.2) { self.counter.transform = .identity }
                }
                continue
            }
            if case .barcode(let code) = item, let value = code.payloadStringValue, !value.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dataScanner.stopScanning()
                dataScanner.dismiss(animated: true)
                finish(value)
                return
            }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        dataScanner.dismiss(animated: true)
        finish(nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(nil)
    }

    private func finish(_ value: Any?) {
        let d = done
        done = nil
        d?(value)
    }
}
