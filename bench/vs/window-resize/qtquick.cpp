// Qt's XCB platform, resize delivery, QML bindings and native software scene graph.
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "xcb");
    qputenv("QT_QUICK_BACKEND", "software");
    QGuiApplication app(argc, argv);
    QQuickWindow window;
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData(R"(
        import QtQuick
        Rectangle {
            anchors.fill: parent
            color: width % 4 === 0 ? "#223344" : "#516273"
            Rectangle { anchors.centerIn: parent; width: 64; height: 64; color: "#e67e28" }
        }
    )", QUrl());
    QScopedPointer<QObject> scene(component.create());
    if (!scene) qFatal("%s", qPrintable(component.errorString()));
    qobject_cast<QQuickItem *>(scene.data())->setParentItem(window.contentItem());
    window.setTitle("resize-qtquick");
    window.resize(800, 600);
    window.show();
    return app.exec();
}
