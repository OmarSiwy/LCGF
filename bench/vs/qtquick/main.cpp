// The scenes of bench/scenes/ on Qt Quick 6 (QML), for the comparison of docs/perf/vs.md.
// Qt Quick is retained, with property bindings and a scene graph: each scene's QML is created once,
// a frame sets that frame's changes (a mouse move, the ListView's contentY, the bar widths, the
// window size) and QQuickWindow::grabWindow, which polishes (layouts), syncs the scene graph and
// renders it with Qt Quick's software back end into an image. So a frame includes rasterisation
// of the whole window, which bench/micro's does not, and Qt cannot be asked to skip an unchanged
// frame here: grabWindow always renders. The idle scene instead lets Qt's own render loop decide
// (events processed, frames counted by frameSwapped), and `--idle` runs QGuiApplication::exec.
//
// Platform: QT_QPA_PLATFORM=offscreen, QT_QUICK_BACKEND=software, Qt Quick Controls style Basic.
// Widgets are Qt Quick Controls (TextField, CheckBox, Slider, Button) and a ListView over 100,000
// rows; text is rendered from the system fonts at 14 and 20 px. Springs come from harness.h.
#include <QGuiApplication>
#include <QImage>
#include <QMouseEvent>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSocketNotifier>
#include <QVariantList>
#include "../harness.h"

static const char *const header = R"(
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
)";

static const char *const form_qml = R"(
Rectangle {
    anchors.fill: parent
    color: "#1e1f24"
    property var names: []
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 4
        Text { text: "Account settings"; font.pixelSize: 20; color: "#e6e6eb" }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#4a4d5a" }
        Repeater {
            model: names
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text { text: modelData; Layout.preferredWidth: 90; color: "#e6e6eb"; font.pixelSize: 14 }
                TextField { text: modelData; Layout.fillWidth: true; font.pixelSize: 14 }
                CheckBox { text: "On"; font.pixelSize: 14 }
                Slider { from: 0; to: 1; value: 0.5; Layout.fillWidth: true }
            }
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 6
            Button { text: "Cancel"; font.pixelSize: 14 }
            Button { text: "Reset"; font.pixelSize: 14 }
            Button { text: "Save"; font.pixelSize: 14 }
        }
        Item { Layout.fillHeight: true }
    }
}
)";

static const char *const list_qml = R"(
Rectangle {
    anchors.fill: parent
    color: "#1e1f24"
    property alias scroll: view.contentY
    readonly property var names: ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
    ListView {
        id: view
        anchors.fill: parent
        model: 100000
        delegate: Rectangle {
            required property int index
            width: ListView.view.width
            height: 24
            color: index % 2 ? "#3a3c46" : "#1e1f24"
            Row {
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Text { text: "Row " + index; color: "#e6e6eb"; font.pixelSize: 14 }
                Text { text: names[index % 7]; color: "#e6e6eb"; font.pixelSize: 14 }
                Rectangle { width: 12; height: 12; color: "#5a8cff"; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }
}
)";

static const char *const text_qml = R"(
Rectangle {
    anchors.fill: parent
    color: "#1e1f24"
    clip: true
    property var prose: []
    Row {
        x: 12; y: 12
        spacing: 16
        Column {
            width: 160
            spacing: 2
            Repeater { model: 120; Text { text: "Chapter " + (index + 1); color: "#e6e6eb"; font.pixelSize: 14 } }
        }
        Column {
            id: main
            width: parent.parent.width - 160 - 16 - 24
            spacing: 8
            Repeater {
                model: 12
                Column {
                    id: section
                    property int si: index
                    width: main.width
                    spacing: 8
                    Text { text: "Section " + (section.si + 1); color: "#e6e6eb"; font.pixelSize: 20 }
                    Repeater {
                        model: 4
                        Text { width: section.width; wrapMode: Text.WordWrap; text: prose[(section.si + index) % 4]; color: "#e6e6eb"; font.pixelSize: 14 }
                    }
                }
            }
        }
    }
}
)";

static const char *const springs_qml = R"(
Rectangle {
    anchors.fill: parent
    color: "#1e1f24"
    property list<real> widths: []
    Column {
        x: 8; y: 8
        spacing: 2
        Repeater {
            model: 40
            Row {
                id: line
                property int r: index
                spacing: 2
                Repeater { model: 25; Rectangle { width: widths[line.r * 25 + index] || 4; height: 16; color: "#5a8cff" } }
            }
        }
    }
}
)";

static QQuickWindow *window;
static QQuickItem *root;
static VsSprings springs_state;
static uint64_t swapped;

static void create(int scene) {
    const char *body = scene == VS_LIST ? list_qml : scene == VS_TEXT || scene == VS_RESIZE ? text_qml : scene == VS_SPRINGS ? springs_qml : form_qml;
    static QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData(QByteArray(header) + body, QUrl());
    QObject *obj = component.create();
    if (!obj) {
        fprintf(stderr, "%s\n", qPrintable(component.errorString()));
        exit(1);
    }
    root = qobject_cast<QQuickItem *>(obj);
    QVariantList names, prose;
    for (const char *n : vs_form_names) names << QString(n);
    for (const char *p : vs_prose) prose << QString(p);
    root->setProperty("names", names);
    root->setProperty("prose", prose);
    root->setParentItem(window->contentItem());
}

static void apply(int scene, const VsInput &in) {
    window->resize((int)in.w, (int)in.h);
    QPointF p(in.px, in.py);
    QMouseEvent move(QEvent::MouseMove, p, p, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(window, &move);
    if (scene == VS_LIST) root->setProperty("scroll", (double)in.scroll);
    if (scene == VS_SPRINGS) {
        vs_springs_step(&springs_state, in.tick, in.dt);
        QList<qreal> widths;
        widths.reserve(1000);
        for (float x : springs_state.x) widths << x;
        root->setProperty("widths", QVariant::fromValue(widths));
    }
}

static VsInput last_in;
static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    if (k == 0) create(scene);
    if (scene == VS_IDLE) {
        // Qt's own render loop decides: post only what changed, let it run, count frames swapped.
        uint64_t before = swapped;
        if (k == 0 || memcmp(&in, &last_in, sizeof in)) apply(scene, in);
        last_in = in;
        QCoreApplication::processEvents();
        return swapped - before;
    }
    apply(scene, in);
    QImage image = window->grabWindow();
    return (uint64_t)image.sizeInBytes();
}

// Qt's own event loop until stdin closes.
static void vs_idle(void) {
    QSocketNotifier stdin_closed(0, QSocketNotifier::Read);
    QObject::connect(&stdin_closed, &QSocketNotifier::activated, [] {
        char byte;
        if (read(0, &byte, 1) <= 0) QCoreApplication::quit();
    });
    QGuiApplication::exec();
}

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("QT_QUICK_BACKEND", "software");
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    int qt_argc = 1;
    QGuiApplication app(qt_argc, argv);
    QQuickWindow w;
    window = &w;
    QObject::connect(&w, &QQuickWindow::frameSwapped, [] { swapped++; });
    w.resize(800, 600);
    w.show();
    return vs_main(argc, argv, "qtquick-" QT_VERSION_STR);
}
