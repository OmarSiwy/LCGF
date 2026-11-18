// Qt Widgets retains each scene. A changing frame applies the input and layout requests,
// then QWidget::grab paints the window and all its children into a software pixmap. The
// idle scene observes ordinary window paints and --idle sleeps in QApplication::exec().
#include <QAbstractListModel>
#include <QApplication>
#include <QBoxLayout>
#include <QCheckBox>
#include <QFrame>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QMouseEvent>
#include <QPainter>
#include <QPixmap>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QSlider>
#include <QSocketNotifier>
#include <QStyledItemDelegate>
#include <QWindow>
#include "../harness.h"

static const QColor panel(30, 31, 36), control(58, 60, 70), accent(90, 140, 255);
static constexpr int rowHeight = 24;

class SceneWindow : public QWidget {
public:
    uint64_t paints = 0;
protected:
    void paintEvent(QPaintEvent *event) override {
        ++paints;
        QWidget::paintEvent(event);
    }
};

class Rows : public QAbstractListModel {
public:
    using QAbstractListModel::QAbstractListModel;
    int rowCount(const QModelIndex &parent = {}) const override { return parent.isValid() ? 0 : 100000; }
    QVariant data(const QModelIndex &index, int role) const override {
        if (!index.isValid() || role != Qt::DisplayRole) return {};
        return QStringLiteral("Row %1").arg(index.row());
    }
};

class RowDelegate : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    QSize sizeHint(const QStyleOptionViewItem &, const QModelIndex &) const override {
        return QSize(1, rowHeight);
    }
    void paint(QPainter *p, const QStyleOptionViewItem &o, const QModelIndex &index) const override {
        p->fillRect(o.rect, index.row() % 2 ? control : panel);
        const auto number = index.data().toString();
        const auto name = QString::fromLatin1(vs_list_names[index.row() % 7]);
        const auto metrics = o.fontMetrics;
        p->save();
        p->setFont(o.font);
        p->setPen(QColor(230, 230, 235));
        const int baseline = o.rect.top() + (rowHeight - metrics.height()) / 2 + metrics.ascent();
        int x = o.rect.left() + 8;
        p->drawText(x, baseline, number);
        x += metrics.horizontalAdvance(number) + 6;
        p->drawText(x, baseline, name);
        x += metrics.horizontalAdvance(name) + 6;
        p->fillRect(x, o.rect.top() + (rowHeight - 12) / 2, 12, 12, accent);
        p->restore();
    }
};

static SceneWindow *window;
static QListView *listView;
static QWidget *bars[1000];
static VsSprings springs;
static VsInput previous;

static QLabel *heading(const QString &text) {
    auto *label = new QLabel(text);
    QFont font = label->font();
    font.setPixelSize(20);
    label->setFont(font);
    return label;
}

static void form(QVBoxLayout *column) {
    column->setSpacing(4);
    column->addWidget(heading("Account settings"));
    auto *separator = new QFrame;
    separator->setFrameShape(QFrame::HLine);
    column->addWidget(separator);
    for (const char *name : vs_form_names) {
        auto *row = new QHBoxLayout;
        row->setSpacing(6);
        auto *label = new QLabel(QString::fromUtf8(name));
        label->setFixedWidth(90);
        row->addWidget(label);
        auto *field = new QLineEdit(QString::fromUtf8(name));
        field->setFixedWidth(220);
        row->addWidget(field);
        row->addWidget(new QCheckBox("On"));
        auto *slider = new QSlider(Qt::Horizontal);
        slider->setRange(0, 100);
        slider->setValue(50);
        row->addWidget(slider, 1);
        column->addLayout(row);
    }
    auto *footer = new QHBoxLayout;
    footer->addStretch();
    for (const auto *name : {"Cancel", "Reset", "Save"}) footer->addWidget(new QPushButton(name));
    column->addLayout(footer);
    column->addStretch();
}

static void list(QVBoxLayout *column) {
    column->setContentsMargins(0, 0, 0, 0);
    listView = new QListView;
    listView->setFrameShape(QFrame::NoFrame);
    listView->setUniformItemSizes(true);
    listView->setSelectionMode(QAbstractItemView::NoSelection);
    listView->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    listView->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    listView->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    listView->setModel(new Rows(listView));
    listView->setItemDelegate(new RowDelegate(listView));
    column->addWidget(listView);
}

static void prose(QVBoxLayout *column) {
    auto *area = new QScrollArea;
    area->setFrameShape(QFrame::NoFrame);
    area->setWidgetResizable(true);
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    auto *document = new QWidget;
    auto *columns = new QHBoxLayout(document);
    columns->setContentsMargins(0, 0, 0, 0);
    columns->setSpacing(16);
    auto *sidebar = new QWidget;
    sidebar->setFixedWidth(160);
    auto *chapters = new QVBoxLayout(sidebar);
    chapters->setContentsMargins(0, 0, 0, 0);
    chapters->setSpacing(2);
    for (int i = 1; i <= 120; ++i) chapters->addWidget(new QLabel(QStringLiteral("Chapter %1").arg(i)));
    chapters->addStretch();
    columns->addWidget(sidebar);
    auto *body = new QVBoxLayout;
    body->setSpacing(8);
    for (int s = 0; s < 12; ++s) {
        body->addWidget(heading(QStringLiteral("Section %1").arg(s + 1)));
        for (int p = 0; p < 4; ++p) {
            auto *text = new QLabel(QString::fromUtf8(vs_prose[(s + p) % 4]));
            text->setWordWrap(true);
            body->addWidget(text);
        }
    }
    body->addStretch();
    columns->addLayout(body, 1);
    area->setWidget(document);
    column->addWidget(area);
}

static void grid(QVBoxLayout *column) {
    column->setContentsMargins(8, 8, 8, 8);
    column->setSpacing(2);
    QPalette palette = window->palette();
    palette.setColor(QPalette::Window, accent);
    for (int r = 0; r < 40; ++r) {
        auto *row = new QHBoxLayout;
        row->setSpacing(2);
        for (int c = 0; c < 25; ++c) {
            auto *bar = new QWidget;
            bar->setPalette(palette);
            bar->setAutoFillBackground(true);
            bar->setFixedSize(4, 16);
            bars[r * 25 + c] = bar;
            row->addWidget(bar);
        }
        row->addStretch();
        column->addLayout(row);
    }
    column->addStretch();
}

static uint64_t vs_frame(int scene, uint32_t k) {
    const VsInput in = vs_input(scene, k);
    const auto before = window->paints;
    if (k == 0) {
        window->resize(int(in.w), int(in.h));
        auto *column = new QVBoxLayout(window);
        column->setContentsMargins(12, 12, 12, 12);
        column->setSizeConstraint(QLayout::SetNoConstraint);
        if (scene == VS_LIST) list(column);
        else if (scene == VS_SPRINGS) grid(column);
        else if (scene == VS_TEXT || scene == VS_RESIZE) prose(column);
        else form(column);
        window->setFocusPolicy(Qt::StrongFocus);
        window->show();
        window->setFocus();
    }
    if (in.w != previous.w || in.h != previous.h) window->resize(int(in.w), int(in.h));
    if (k == 0 || in.px != previous.px || in.py != previous.py) {
        const QPointF point(in.px, in.py);
        QMouseEvent move(QEvent::MouseMove, point, window->mapToGlobal(point), Qt::NoButton, Qt::NoButton, {});
        QCoreApplication::sendEvent(window->windowHandle(), &move);
    }
    previous = in;
    if (scene == VS_IDLE) {
        QCoreApplication::processEvents();
        return window->paints - before;
    }
    if (scene == VS_LIST) listView->verticalScrollBar()->setValue(int(in.scroll));
    if (scene == VS_SPRINGS) {
        vs_springs_step(&springs, in.tick, in.dt);
        for (int i = 0; i < 1000; ++i) bars[i]->setFixedWidth(qRound(springs.x[i]));
    }
    QCoreApplication::sendPostedEvents(nullptr, QEvent::LayoutRequest);
    const QPixmap frame = window->grab();
    if (frame.isNull()) qFatal("Qt Widgets produced an empty frame");
    return uint64_t(frame.width()) * frame.height();
}

static void vs_idle() {
    QSocketNotifier stdinReady(STDIN_FILENO, QSocketNotifier::Read);
    QObject::connect(&stdinReady, &QSocketNotifier::activated, [] {
        char byte;
        if (read(STDIN_FILENO, &byte, 1) <= 0) QCoreApplication::quit();
    });
    QApplication::exec();
}

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    int qtArgc = 1;
    QApplication app(qtArgc, argv);
    QFont font = app.font();
    font.setPixelSize(14);
    app.setFont(font);
    SceneWindow scene;
    window = &scene;
    return vs_main(argc, argv, "qtwidgets-" QT_VERSION_STR);
}
