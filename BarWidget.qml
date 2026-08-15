import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

BarWidget {
    id: root
    moduleName: "mus.quran"

    readonly property var quranService: bar && bar.shell ? bar.shell.firstPartyServiceFor("mus.quran") : null
    // readonly property string iconGlyph: ""
    readonly property string iconGlyph: ""

    //

    // Popup theme roles (bound to the shell Color singleton, never hex).
    readonly property color fg: Color.popups.text
    readonly property color accentC: Color.accent
    readonly property color mutedC: Color.muted

    property bool popupOpen: false
    property string activeTab: "surah" // "surah" | "reciter"
    property string surahQuery: ""
    property string reciterQuery: ""
    property int listCursor: 0

    // Collapsible browse section: starts collapsed on every popup open.
    property bool browseExpanded: false
    property bool settingsOpen: false

    // Download prompt state (first-selection full-mushaf prompt)
    property var pendingDownloadReciter: null // { identifier, name, englishName }

    readonly property var currentSurah: quranService ? quranService.currentSurah : null
    readonly property var currentReciter: quranService ? quranService.currentReciter : null
    readonly property var filteredSurahs: Model.filterSurahs(quranService ? quranService.surahs : [], root.surahQuery)
    readonly property var filteredReciters: Model.filterReciters(quranService ? quranService.reciters : [], root.reciterQuery)

    // Filtering is cheap, but delegate creation is not. Coalesce rapid
    // keystrokes so the virtualized list only receives settled queries.
    Timer {
        id: reciterSearchTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (root.activeTab === "reciter") {
                root.reciterQuery = searchField.text;
                root.listCursor = 0;
            }
        }
    }

    function lang() {
        return quranService ? quranService.language : Model.DEFAULT_LANGUAGE;
    }

    function tr(key) {
        return Model.tr(root.lang(), key);
    }
    function trArgs(key, args) {
        return Model.trArgs(root.lang(), key, args);
    }

    function currentFiltered() {
        return root.activeTab === "surah" ? root.filteredSurahs : root.filteredReciters;
    }

    // Contract KeyboardPanel expects on its `owner`
    function close() {
        root.browseExpanded = false;
        root.settingsOpen = false;
        root.popupOpen = false;
    }

    onPopupOpenChanged: {
        if (root.popupOpen && quranService)
            quranService.refreshCacheSize();
    }

    function playSurah(n) {
        if (!quranService)
            return;
        var id = quranService.reciterId || Model.DEFAULT_RECITER;
        // Playing is always streaming-by-default. Downloading is an explicit
        // action on the row icon or in the reciter tab.
        quranService.playSurah(id, n);
        root.close();
    }

    // Reciter selection keeps the popup open and hops to the surah tab; the
    // download prompt (if any) floats above it.
    function pickReciter(id) {
        if (!quranService)
            return;
        quranService.selectReciter(id);
        root.activeTab = "surah";
        root.listCursor = 0;
        if (quranService.shouldPrompt(id))
            root.pendingDownloadReciter = quranService.reciterFor(id) || {
                identifier: id,
                name: "",
                englishName: id
            };
    }

    function declineDownload() {
        if (quranService && root.pendingDownloadReciter) {
            quranService.setReciterStatus(root.pendingDownloadReciter.identifier, "declined");
        }
        root.pendingDownloadReciter = null;
    }

    // j/k + Enter navigation over the visible list.
    function moveCursor(dy) {
        var count = root.currentFiltered().length;
        if (count === 0)
            return;
        root.listCursor = (root.listCursor + dy + count) % count;
    }

    function activateCursor() {
        if (root.activeTab === "surah") {
            var s = root.filteredSurahs[root.listCursor];
            if (s)
                root.playSurah(s.number);
        } else {
            var r = root.filteredReciters[root.listCursor];
            if (r)
                root.pickReciter(r.identifier);
        }
    }

    // --- bar icon -----------------------------------------------------------

    visible: true
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.iconGlyph
        tooltipText: quranService && quranService.hasMedia ? (quranService.surahLabel(quranService.surahNumber) + " — " + quranService.reciterLabel()) : root.tr("tooltip")
        onPressed: function (b) {
            if (b === Qt.RightButton || b === Qt.MiddleButton) {
                if (quranService)
                    quranService.playPause();
            } else {
                root.browseExpanded = false;
                root.settingsOpen = false;
                root.popupOpen = !root.popupOpen;
            }
        }
        onWheelMoved: function (delta) {
            if (!quranService)
                return;
            if (delta > 0)
                quranService.previous();
            else
                quranService.next();
        }
    }

    // --- popup --------------------------------------------------------------

    KeyboardPanel {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.popupOpen
        focusTarget: keyCatcher
        padding: Style.space(20)
        contentWidth: popup.fittedContentWidth(Style.space(340))
        contentHeight: popup.fittedContentHeight(root.settingsOpen ? settingsCol.implicitHeight : col.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: searchField.activeFocus || languageDropdown.popupOpen
            onMoveRequested: function (dx, dy) {
                if (dy !== 0)
                    root.moveCursor(dy);
            }
            onActivateRequested: root.activateCursor()
            onCloseRequested: root.close()

            Column {
                id: col
                anchors.fill: parent
                spacing: 0
                visible: !root.settingsOpen

                // ---- 1. now-playing header ----
                Item {
                    width: parent.width
                    height: Math.max(headerRow.implicitHeight, settingsButton.implicitHeight)
                    implicitHeight: height

                    Row {
                        id: headerRow
                        anchors.left: parent.left
                        anchors.right: settingsButton.left
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(10)

                        BorderSurface {
                            width: Style.space(64)
                            height: Style.space(64)
                            radius: Style.spacing.labelGap
                            color: Style.normalFillFor(root.fg, root.accentC)
                            borderSpec: Border.controlSpec("normal", root.fg, root.accentC)

                            Text {
                                anchors.centerIn: parent
                                text: root.iconGlyph
                                color: root.fg
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.displayLarge
                            }
                        }

                        Column {
                            width: parent.width - Style.space(74)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(4)

                            Text {
                                width: parent.width
                                text: currentSurah ? Model.surahDisplayLabel(currentSurah, root.lang()) : root.tr("noSurahSelected")
                                color: root.fg
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.subtitle
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: currentReciter ? Model.reciterDisplayLabel(currentReciter, root.lang()) : "Quran Player"
                                color: root.mutedC
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Item {
                        id: settingsButton
                        anchors.right: parent.right
                        anchors.top: parent.top
                        width: Style.space(28)
                        height: Style.space(28)

                        Text {
                            anchors.centerIn: parent
                            text: "󰒓"
                            color: settingsArea.containsMouse ? root.accentC : root.mutedC
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.title
                        }

                        MouseArea {
                            id: settingsArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.settingsOpen = true
                        }

                        PanelToolTip {
                            visible: settingsArea.containsMouse
                            text: root.tr("settings")
                            fontFamily: root.bar.fontFamily
                        }
                    }
                }

                Item {
                    width: 1
                    height: Style.space(20)
                    implicitHeight: Style.space(20)
                }

                // ---- 2. seek bar + time labels (below the bar) ----
                Column {
                    width: parent.width
                    spacing: Style.space(8)

                    Item {
                        id: seekBar
                        width: parent.width
                        height: Style.space(20)
                        implicitHeight: height

                        readonly property int dur: quranService && quranService.player ? quranService.player.duration : 0
                        readonly property int pos: quranService && quranService.player ? quranService.player.position : 0
                        readonly property real frac: dur > 0 ? Math.min(1, Math.max(0, pos / dur)) : 0
                        property real dragFrac: -1

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: Style.space(2)
                            radius: height / 2
                            color: Util.alpha(root.mutedC, 0.35)
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * (seekBar.dragFrac >= 0 ? seekBar.dragFrac : seekBar.frac)
                            height: Style.space(2)
                            radius: height / 2
                            color: root.accentC
                        }

                        Rectangle {
                            x: Math.max(0, Math.min(parent.width - width, parent.width * (seekBar.dragFrac >= 0 ? seekBar.dragFrac : seekBar.frac) - width / 2))
                            y: (parent.height - height) / 2
                            width: Style.space(8)
                            height: Style.space(8)
                            radius: width / 2
                            color: root.accentC
                            visible: seekBar.dur > 0
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: seekBar.dur > 0 && quranService && quranService.player && quranService.player.seekable
                            onPressed: function (m) {
                                seekBar.dragFrac = Math.min(1, Math.max(0, m.x / width));
                            }
                            onPositionChanged: function (m) {
                                if (pressed)
                                    seekBar.dragFrac = Math.min(1, Math.max(0, m.x / width));
                            }
                            onReleased: function () {
                                if (quranService && seekBar.dragFrac >= 0)
                                    quranService.seek(Math.round(seekBar.dragFrac * seekBar.dur));
                                seekBar.dragFrac = -1;
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: elapsedText.implicitHeight

                        Text {
                            id: elapsedText
                            anchors.left: parent.left
                            text: quranService && quranService.player ? Model.formatTime(quranService.player.position) : "0:00"
                            color: root.mutedC
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            anchors.right: parent.right
                            text: quranService && quranService.player ? Model.formatTime(quranService.player.duration) : "0:00"
                            color: root.mutedC
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }

                Item {
                    width: 1
                    height: Style.space(20)
                    implicitHeight: Style.space(20)
                }

                // ---- 3. transport row ----
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(26)

                    Button {
                        width: Style.space(36)
                        implicitHeight: Style.space(36)
                        horizontalPadding: 0
                        verticalPadding: 0
                        iconText: quranService && quranService.playbackMode === Model.MODE_CONTINUE ? "󰐌" : quranService && quranService.playbackMode === Model.MODE_REPEAT_ONE ? "󰑘" : quranService && quranService.playbackMode === Model.MODE_REPEAT_ALL ? "󰑖" : "󰐍"
                        foreground: root.fg
                        tooltipText: Model.modeLabel(root.lang(), quranService ? quranService.playbackMode : Model.MODE_SINGLE)
                        onClicked: if (quranService)
                            quranService.cycleMode()
                    }

                    Button {
                        width: Style.space(36)
                        implicitHeight: Style.space(36)
                        horizontalPadding: 0
                        verticalPadding: 0
                        iconText: "󰒮"
                        foreground: root.fg
                        onClicked: if (quranService)
                            quranService.previous()
                    }

                    Item {
                        width: Style.space(36)
                        height: Style.space(36)
                        implicitHeight: Style.space(36)

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: "transparent"
                            border.color: Util.alpha(root.mutedC, 0.55)
                            border.width: 1
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            visible: playArea.containsMouse
                            color: Util.alpha(root.fg, 0.07)
                        }

                        Text {
                            anchors.centerIn: parent
                            text: quranService && quranService.isPlaying ? "󰏤" : "󰐊"
                            color: root.fg
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.iconLarge
                        }

                        MouseArea {
                            id: playArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (quranService)
                                quranService.playPause()
                        }
                    }

                    Button {
                        width: Style.space(36)
                        implicitHeight: Style.space(36)
                        horizontalPadding: 0
                        verticalPadding: 0
                        iconText: "󰒭"
                        foreground: root.fg
                        onClicked: if (quranService)
                            quranService.next()
                    }

                    Button {
                        width: Style.space(36)
                        implicitHeight: Style.space(36)
                        horizontalPadding: 0
                        verticalPadding: 0
                        iconText: "󰓛"
                        foreground: root.mutedC
                        onClicked: if (quranService)
                            quranService.stopPlayback()
                    }
                }

                Item {
                    width: 1
                    height: Style.space(20)
                    implicitHeight: Style.space(20)
                }

                // ---- 4. browse toggle row ----
                MouseArea {
                    width: parent.width
                    height: browseToggle.implicitHeight
                    implicitHeight: height
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.browseExpanded = !root.browseExpanded

                    Column {
                        id: browseToggle
                        width: parent.width
                        spacing: Style.space(12)

                        Rectangle {
                            width: parent.width
                            height: Style.spaceReal(0.5)
                            color: Util.alpha(root.mutedC, 0.35)
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Style.space(6)

                            Text {
                                text: root.tr("browse")
                                color: root.mutedC
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                font.weight: Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: root.browseExpanded ? "" : ""
                                color: root.mutedC
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                // ---- 5. collapsible browse section ----
                Item {
                    id: browseBlock
                    width: parent.width
                    clip: true
                    height: root.browseExpanded ? Style.space(20) + browseContent.implicitHeight : 0
                    implicitHeight: height

                    Behavior on height {
                        NumberAnimation {
                            duration: 150
                            easing.type: Easing.OutCubic
                        }
                    }

                    Column {
                        id: browseContent
                        width: parent.width
                        spacing: 0

                        Item {
                            width: 1
                            height: Style.space(20)
                            implicitHeight: Style.space(20)
                        }

                        // ---- error / loading ----
                        Column {
                            width: parent.width
                            spacing: Style.space(4)
                            visible: quranService && (quranService.errorMessage !== "" || quranService.recitersLoading)

                            Text {
                                width: parent.width
                                visible: quranService && quranService.errorMessage !== ""
                                text: quranService ? quranService.errorMessage : ""
                                color: root.bar.urgent
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                            }

                            Row {
                                visible: quranService && quranService.errorMessage !== ""
                                spacing: Style.space(6)

                                Button {
                                    text: root.tr("retry")
                                    foreground: root.fg
                                    horizontalPadding: Style.spacing.controlPaddingX
                                    verticalPadding: Style.spacing.controlPaddingY
                                    onClicked: {
                                        if (!quranService)
                                            return;
                                        if (quranService.lastDownload && quranService.errorMessage === root.tr("downloadFailed"))
                                            quranService.retryDownload();
                                        else
                                            quranService.retry();
                                    }
                                }
                            }

                            Text {
                                width: parent.width
                                visible: quranService && quranService.recitersLoading
                                text: root.tr("loadingReciters")
                                color: root.mutedC
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        // ---- tabs ----
                        Row {
                            width: parent.width
                            spacing: Style.space(6)

                            Button {
                                width: (parent.width - parent.spacing) / 2
                                text: root.tr("tabSurah")
                                selected: root.activeTab === "surah"
                                bordered: true
                                foreground: root.fg
                                onClicked: {
                                    root.activeTab = "surah";
                                    root.listCursor = 0;
                                }
                            }

                            Button {
                                width: (parent.width - parent.spacing) / 2
                                text: root.tr("tabReciter")
                                selected: root.activeTab === "reciter"
                                bordered: true
                                foreground: root.fg
                                onClicked: {
                                    root.activeTab = "reciter";
                                    root.listCursor = 0;
                                }
                            }
                        }

                        Item {
                            width: 1
                            height: Style.space(10)
                            implicitHeight: Style.space(10)
                        }

                        // ---- search + list ----
                        Column {
                            width: parent.width
                            spacing: Style.space(4)

                            TextField {
                                id: searchField
                                width: parent.width
                                placeholderText: root.activeTab === "surah" ? root.tr("searchSurah") : root.tr("searchReciter")
                                foreground: root.fg
                                font.family: root.bar.fontFamily
                                text: root.activeTab === "surah" ? root.surahQuery : root.reciterQuery
                                onTextChanged: {
                                    if (root.activeTab === "surah")
                                        root.surahQuery = text;
                                    else {
                                        reciterSearchTimer.restart();
                                    }
                                    if (root.activeTab === "surah")
                                        root.listCursor = 0;
                                }
                            }

                            ListView {
                                id: listView
                                width: parent.width
                                height: Math.min(260, Math.max(Style.space(36), contentHeight))
                                implicitHeight: height
                                clip: true
                                spacing: Style.space(1)
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.activeTab === "surah" ? root.filteredSurahs : root.filteredReciters

                                delegate: BorderSurface {
                                            id: rowDelegate
                                            required property var modelData
                                            required property int index

                                            readonly property var surah: root.activeTab === "surah" ? modelData : null
                                            readonly property var reciter: root.activeTab === "reciter" ? modelData : null
                                            readonly property bool selected: root.activeTab === "surah" ? (quranService && surah.number === quranService.surahNumber) : (quranService && reciter.identifier === quranService.reciterId)
                                            readonly property bool hoveredCursor: index === root.listCursor
                                            readonly property int downloadRevision: quranService ? quranService.downloadRevision : 0
                                            readonly property bool fullDownloaded: {
                                                downloadRevision;
                                                return root.activeTab === "reciter" && quranService ? quranService.isMushafDownloaded(reciter.identifier) : false;
                                            }
                                            readonly property bool surahDownloaded: {
                                                downloadRevision;
                                                return root.activeTab === "surah" && quranService ? quranService.isSurahDownloaded(quranService.reciterId, surah.number) : false;
                                            }
                                            readonly property bool isDownloading: root.activeTab === "surah" ? (quranService ? quranService.isSurahDownloading(quranService.reciterId, surah.number) : false) : (quranService ? quranService.isReciterDownloading(reciter.identifier) : false)

                                            readonly property color rowTitle: selected ? Qt.lighter(root.accentC, 1.2) : root.fg
                                            readonly property color rowSubtitle: selected ? Util.alpha(root.accentC, 0.75) : root.mutedC
                                            readonly property color actionColor: surahDownloaded || fullDownloaded || isDownloading ? root.accentC : root.mutedC

                                            width: listView.width
                                            height: rowInner.implicitHeight + Style.space(16)
                                            radius: Style.space(8)
                                            color: selected ? Util.alpha(root.accentC, 0.16) : (hoveredCursor ? Util.alpha(root.fg, 0.07) : "transparent")
                                            borderSpec: selected ? Border.flat(root.accentC, "0 0 0 2") : Border.none()

                                            // Row click handler is declared BEFORE the row content so the
                                            // download action (below) sits above it in z-order; otherwise the
                                            // full-size MouseArea swallows the icon clicks.
                                            MouseArea {
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (root.activeTab === "surah")
                                                        root.playSurah(surah.number);
                                                    else
                                                        root.pickReciter(reciter.identifier);
                                                }
                                            }

                                            Row {
                                                id: rowInner
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: parent.borderLeft + Style.space(8)
                                                anchors.rightMargin: parent.borderRight + Style.space(8)
                                                spacing: Style.space(8)

                                                Text {
                                                    text: root.activeTab === "surah" ? (selected ? "󰕾" : (surah.number + "")) : (selected ? "󰐊" : "󰐍")
                                                    color: selected ? root.accentC : root.mutedC
                                                    font.family: root.bar.fontFamily
                                                    font.pixelSize: root.activeTab === "surah" && selected ? Style.space(13) : Style.font.bodySmall
                                                    width: Style.space(24)
                                                    horizontalAlignment: Text.AlignHCenter
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }

                                                Column {
                                                    width: parent.width - Style.space(64)
                                                    spacing: Style.space(1)
                                                    anchors.verticalCenter: parent.verticalCenter

                                                    Text {
                                                        text: root.activeTab === "surah" ? Model.surahListLabel(surah, root.lang()) : Model.reciterDisplayLabel(reciter, root.lang())
                                                        color: rowDelegate.rowTitle
                                                        font.family: root.bar.fontFamily
                                                        font.pixelSize: Style.font.bodySmall
                                                        font.weight: selected ? Font.Medium : Font.Normal
                                                        elide: Text.ElideRight
                                                        width: parent.width
                                                    }

                                                    Text {
                                                        text: root.activeTab === "surah" && surah ? (surah.transliteration + " · " + surah.type) : (reciter && reciter.name !== "" ? reciter.name : "")
                                                        color: rowDelegate.rowSubtitle
                                                        font.family: root.bar.fontFamily
                                                        font.pixelSize: Style.font.caption
                                                        elide: Text.ElideRight
                                                        width: parent.width
                                                        visible: text !== ""
                                                    }
                                                }

                                                // Download status icon: outline (muted) → web-style spinner
                                                // (accent) → check-circle (accent). Dedicated 24x24 hit area with its own
                                                // MouseArea so the click downloads instead of falling through to
                                                // the row (select/play).
                                                Item {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: Style.space(24)
                                                    height: Style.space(24)
                                                    implicitHeight: height
                                                    z: 10

                                                    Rectangle {
                                                        anchors.fill: parent
                                                        z: 10
                                                        radius: Style.spacing.labelGap
                                                        color: downloadActionArea.containsMouse ? Util.alpha(root.accentC, 0.14) : "transparent"
                                                        border.color: downloadActionArea.containsMouse ? Util.alpha(root.accentC, 0.55) : "transparent"
                                                        border.width: 1
                                                    }

                                                    Text {
                                                        anchors.centerIn: parent
                                                        visible: !isDownloading
                                                        text: root.activeTab === "surah" ? (surahDownloaded ? "󰗠" : "󰇚") : (fullDownloaded ? "󰗠" : "󰇚")
                                                        color: rowDelegate.actionColor
                                                        font.family: root.bar.fontFamily
                                                        font.pixelSize: Style.font.bodySmall
                                                    }

                                                    Item {
                                                        anchors.centerIn: parent
                                                        visible: isDownloading
                                                        width: Style.space(18)
                                                        height: Style.space(18)

                                                        // Eight dots with a staggered opacity wave. This is an
                                                        // indeterminate spinner, rather than a glyph rotating in
                                                        // place or a fabricated percentage.
                                                        Repeater {
                                                            model: 8

                                                            Rectangle {
                                                                required property int index
                                                                width: Style.space(3)
                                                                height: Style.space(5)
                                                                radius: width / 2
                                                                color: root.accentC
                                                                x: (parent.width - width) / 2 + Math.sin(index * Math.PI / 4) * Style.space(5.5)
                                                                y: (parent.height - height) / 2 - Math.cos(index * Math.PI / 4) * Style.space(5.5)
                                                                rotation: index * 45

                                                                SequentialAnimation on opacity {
                                                                    loops: Animation.Infinite
                                                                    running: isDownloading
                                                                    PauseAnimation { duration: index * 90 }
                                                                    NumberAnimation { to: 1.0; duration: 140 }
                                                                    PauseAnimation { duration: 450 }
                                                                    NumberAnimation { to: 0.25; duration: 140 }
                                                                    PauseAnimation { duration: (7 - index) * 90 }
                                                                }
                                                            }
                                                        }
                                                    }

                                                    MouseArea {
                                                        id: downloadActionArea
                                                        anchors.fill: parent
                                                        z: 20
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: function (mouse) {
                                                            mouse.accepted = true;
                                                            if (!quranService || isDownloading)
                                                                return;
                                                            if (root.activeTab === "surah")
                                                                Quickshell.execDetached(["omarchy-shell", "quran", "download", quranService.reciterId, String(surah.number)]);
                                                            else
                                                                // IPC requires the surah argument; 0 means the full
                                                                // reciter set and is handled as a mushaf download.
                                                                Quickshell.execDetached(["omarchy-shell", "quran", "download", reciter.identifier, "0"]);
                                                        }
                                                    }

                                                    PanelToolTip {
                                                        visible: downloadActionArea.containsMouse
                                                        text: root.activeTab === "surah" ? (isDownloading ? root.trArgs("downloading", [Model.reciterDisplayLabel(root.currentReciter, root.lang())]) : (surahDownloaded ? root.tr("downloaded") : root.tr("download"))) : (isDownloading ? root.trArgs("downloading", [Model.reciterDisplayLabel(reciter, root.lang())]) : (fullDownloaded ? root.tr("downloaded") : root.tr("download")))
                                                        fontFamily: root.bar.fontFamily
                                                    }
                                                }
                                            }
                                        }
                                }

                            // Empty state is outside the virtualized list so it
                            // does not become a delegate or affect scrolling.
                            Text {
                                width: parent.width
                                visible: root.currentFiltered().length === 0
                                text: root.trArgs("noResults", [root.activeTab === "surah" ? root.surahQuery : root.reciterQuery])
                                color: root.mutedC
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }

            Column {
                id: settingsCol
                anchors.fill: parent
                spacing: Style.space(16)
                visible: root.settingsOpen

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                        width: Style.space(28)
                        implicitHeight: Style.space(28)
                        horizontalPadding: 0
                        verticalPadding: 0
                        iconText: "󰁍"
                        foreground: root.mutedC
                        onClicked: root.settingsOpen = false
                    }

                    Text {
                        text: root.tr("settings")
                        color: root.fg
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.title
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Column {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                        text: root.tr("language")
                        color: root.mutedC
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    SearchableDropdown {
                        id: languageDropdown
                        width: parent.width
                        value: root.lang()
                        options: Model.LANGUAGES
                        showLabel: false
                        foreground: root.fg
                        placeholderText: root.tr("language")
                        onChanged: function (v) {
                            if (quranService)
                                quranService.setLanguage(v);
                        }
                    }
                }

                BorderSurface {
                    id: clearCacheButton
                    width: parent.width
                    height: Style.space(36)
                    radius: Style.spacing.labelGap
                    color: Util.alpha(root.bar.urgent, clearCacheArea.containsMouse ? 0.22 : 0.12)
                    borderSpec: Border.flat(root.bar.urgent, 1)

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰆴"
                        color: root.bar.urgent
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(36)
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.tr("clearCache")
                        color: root.bar.urgent
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        text: quranService ? root.trArgs("cacheSize", [Model.formatSize(quranService.cacheSizeBytes)]) : ""
                        color: root.mutedC
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                        id: clearCacheArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (quranService)
                            quranService.clearCache()
                    }
                }
            }
        }
    }

    // ---- download prompt overlay ----
    KeyboardPanel {
        id: downloadPopup
        anchorItem: button
        bar: root.bar
        owner: root
        open: root.pendingDownloadReciter !== null
        padding: Style.space(20)
        contentWidth: downloadPopup.fittedContentWidth(Style.space(300))
        contentHeight: downloadPopup.fittedContentHeight(downloadCol.implicitHeight)

        Column {
            id: downloadCol
            anchors.fill: parent
            spacing: Style.space(10)

            Row {
                width: parent.width
                spacing: Style.space(10)

                BorderSurface {
                    width: Style.space(48)
                    height: Style.space(48)
                    radius: Style.spacing.labelGap
                    color: Style.normalFillFor(root.fg, root.accentC)
                    borderSpec: Border.controlSpec("normal", root.fg, root.accentC)

                    Text {
                        anchors.centerIn: parent
                        text: root.iconGlyph
                        color: root.fg
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.title
                    }
                }

                Column {
                    width: parent.width - Style.space(58)
                    spacing: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        width: parent.width
                        text: root.tr("download")
                        color: root.fg
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                    }

                    Text {
                        width: parent.width
                        text: root.pendingDownloadReciter ? Model.reciterDisplayLabel(root.pendingDownloadReciter, root.lang()) : ""
                        color: root.accentC
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                    }
                }
            }

            Text {
                width: parent.width
                text: {
                    if (!quranService)
                        return "";
                    if (quranService.downloading)
                        return root.trArgs("downloading", [root.pendingDownloadReciter ? Model.reciterDisplayLabel(root.pendingDownloadReciter, root.lang()) : ""]);
                    var id = root.pendingDownloadReciter ? root.pendingDownloadReciter.identifier : "";
                    if (id) {
                        var missing = quranService.missingCount(id);
                        if (missing > 0 && missing < 114)
                            return root.trArgs("downloadRemaining", [String(missing)]);
                    }
                    return root.tr("downloadDesc");
                }
                color: root.mutedC
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
            }

            // progress bar
            Rectangle {
                width: parent.width
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius
                color: Style.controlFill(false, false, root.fg, root.accentC)
                visible: quranService && quranService.downloading

                Rectangle {
                    width: parent.width * (quranService && quranService.downloadTotal > 0 ? Math.min(1, quranService.downloadDone / quranService.downloadTotal) : 0)
                    height: parent.height
                    radius: Style.cornerRadius
                    color: root.accentC
                }

                Text {
                    anchors.centerIn: parent
                    text: quranService ? (quranService.downloadDone + " / " + quranService.downloadTotal) : ""
                    color: root.fg
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                }
            }

            Row {
                visible: !(quranService && quranService.downloading)
                spacing: Style.space(6)

                Button {
                    text: root.tr("download")
                    foreground: root.fg
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                        if (quranService && root.pendingDownloadReciter) {
                            quranService.downloadMushaf(root.pendingDownloadReciter.identifier);
                            // The prompt is only a first-selection decision;
                            // progress must not keep a modal panel over the UI.
                            root.pendingDownloadReciter = null;
                        }
                    }
                }

                Button {
                    text: root.tr("streamOnly")
                    foreground: root.fg
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: root.declineDownload()
                }

                Button {
                    text: root.tr("close")
                    foreground: root.fg
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: root.pendingDownloadReciter = null
                }
            }
        }
    }
}
