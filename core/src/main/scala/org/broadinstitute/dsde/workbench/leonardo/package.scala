package org.broadinstitute.dsde.workbench

package object leonardo {
  type LabelMap = Map[String, String]
  //this value is the default for autopause, if none is specified. An autopauseThreshold of 0 indicates no autopause
  final val autoPauseOffValue = 0
}