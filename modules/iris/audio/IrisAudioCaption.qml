pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.iris.style
import qs.modules.iris.components

// A group's caption over its card, as on the Audio Engine's pages.
IrisText {
    Layout.leftMargin: 16 * IrisStyle.density
    Layout.topMargin: 10 * IrisStyle.density
    color: IrisStyle.label
    font.family: IrisStyle.fontTitle
    font.pixelSize: IrisStyle.typeMeta
    font.weight: IrisStyle.weight(Font.DemiBold)
}
