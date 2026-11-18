// The window-system resize drives the native QWidget backing store and XCB presentation.
#include <QApplication>
#include <QPainter>
#include <QWidget>

class SceneWindow : public QWidget {
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.fillRect(rect(), width() % 4 == 0 ? QColor(0x22, 0x33, 0x44) : QColor(0x51, 0x62, 0x73));
        painter.fillRect((width() - 64) / 2, (height() - 64) / 2, 64, 64, QColor(0xe6, 0x7e, 0x28));
    }
};

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "xcb");
    QApplication app(argc, argv);
    SceneWindow window;
    window.setAttribute(Qt::WA_OpaquePaintEvent);
    window.setWindowTitle("resize-qtwidgets");
    window.resize(800, 600);
    window.show();
    return app.exec();
}
