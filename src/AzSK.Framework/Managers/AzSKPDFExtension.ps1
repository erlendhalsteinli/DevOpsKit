Set-StrictMode -Version Latest

class AzSKPDFExtension
{
	static [void] GeneratePDF([string] $reportFolderPath, [PSObject] $subscriptionObject, [PSObject] $dataObject, [bool] $isLandscape)
	{
		# Get Context Info
		$executedBy = ([ContextHelper]::GetCurrentRMContext()).Account

		# Verify whether word is installed on machine

		If (test-path HKLM:SOFTWARE\Classes\Word.Application)
		{
			# Initialize word file
			try
			{
				$Word = New-Object -ComObject word.application
				$Word.Visible = $false;
				$AzSKReportDoc = $Word.Documents.Add();
				if($isLandscape)
				{
					$AzSKReportDoc.PageSetup.Orientation = 1
				}
				else
				{
					$AzSKReportDoc.PageSetup.Orientation = 0
				}

				$pdfPath = "$reportFolderPath\SecurityReport.pdf"
				$margin = 36 # 1.26 cm
				$AzSKReportDoc.PageSetup.LeftMargin = $margin
				$AzSKReportDoc.PageSetup.RightMargin = $margin
				#$AzSKReportDoc.PageSetup.TopMargin = $margin
				$AzSKReportDoc.PageSetup.BottomMargin = $margin

				$isSubscriptionCore = $false

				$selection = $Word.Selection
				$selection.WholeStory
				$selection.Style = "No Spacing"

				# Region Front Page
				[AzSKPDFExtension]::WriteText($selection, 'DevSecOps Kit for Azure (AzSK)','Title', $true, $true, $false)
				[AzSKPDFExtension]::WriteText($selection, 'Security Report','TOC Heading', $true, $true, $false)
				$selection.InsertBreak(6)
				$selection.InsertBreak(6)
				$selection.InsertBreak(6)
				$selection.InsertBreak(6)
				$selection.InsertBreak(6)

				$TitleTableRange = $selection.Range();
				$AzSKReportDoc.Tables.Add($TitleTableRange,11,2) | Out-Null
				$AzSKTitleTable = $AzSKReportDoc.Tables.item(1)
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 1, 'Subscription Name', $subscriptionObject.SubscriptionName)
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 2, 'SubscriptionId', $subscriptionObject.SubscriptionId)
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 3, 'AzSK Version', $dataObject.MyCommand.Version.ToString())
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 4, 'Generated by', $dataObject.MyCommand.ModuleName.ToString())
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 5, 'Generated on', (get-date).ToUniversalTime().ToString("MMMM dd, yyyy HH:mm") + " (UTC)")
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 6, 'Requested by', $executedBy.Id.ToString() + " (" + $executedBy.Type.ToString() + ")")
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 7, 'Command Executed', $dataObject.Line.Trim())
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 8, 'Documentation', 'http://aka.ms/azskdocs')
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 9, 'FAQ', 'http://aka.ms/azskdocs/faq')
				[AzSKPDFExtension]::WriteHeaderTableCell($AzSKTitleTable, 10, 'Support DL', [ConfigurationManager]::GetAzSKConfigData().SupportDL)

				$AzSKTitleTable.Borders.OutsideLineStyle = 1
				$AzSKTitleTable.Style = 'Table Grid Light'
				$AzSKTitleTable.Borders.OutsideLineStyle = 1
				$AzSKTitleTable.Borders.InsideLineStyle = 0
				$AzSKTitleTable.Columns.AutoFit()

				$Word.Selection.Start= $AzSKReportDoc.Content.End

				$selection.InsertBreak(7)
				#end region

				# Region TOC
				[AzSKPDFExtension]::WriteText($selection, 'Contents','TOC Heading', $false, $true, $false)
				$range = $Selection.Range
				$toc = $AzSKReportDoc.TablesOfContents.Add($range)
				$selection.TypeParagraph()
				$selection.InsertBreak(7)

				# End region TOC

				# Region Headers/Footers

				#$Section = $AzSKReportDoc.Sections.Item(1)
				#$Header = $Section.Footers.Item(1)
				#$Header.Range.Text = (get-date).ToUniversalTime().ToString("HH:mm MMMM dd, yyyy") + "(UTC)"
				#$Header.Range.Font.Size = 9
				#$Header.Range.ParagraphFormat.Alignment = 2
				$AzSKReportDoc.Sections(1).Footers(1).PageNumbers.Add(2)

				# End region Headers/Footers

				#region -> Add the CSV report
				$selection.TypeText("Security Report Summary");
				$selection.Style = 'Heading 1'
				$selection.TypeParagraph()
				$selection.Style = 'No Spacing'
				$selection.InsertBreak(6)

				$ReportRange = $selection.Range();

				$reportCSVFilePath = @();
				$reportCSVFilePath += Get-ChildItem -Path $reportFolderPath -Filter "*.CSV" -Recurse
				if($reportCSVFilePath.Length -le 0)
				{
					[AzSKPDFExtension]::WriteText($selection, 'Unable to find the required security report under the report folder.','No Spacing', $false, $true, $false)
					[AzSKPDFExtension]::WriteText($selection, 'Or','No Spacing', $true, $true, $false)
					[AzSKPDFExtension]::WriteText($selection, 'No controls have been found to evaluate for the Subscription.','No Spacing', $false, $true, $false)
					#throw "Didn't find the required security report under the report folder.";
				}
				else
				{
					$controls = Import-Csv -Path $reportCSVFilePath[0].FullName
					$isAttestedResult = $false
					if(($controls | Measure-Object).Count -gt 0)
					{
						$Number_Of_Controls = (($controls | Measure-Object).Count +1)
						if($controls[0] | Get-Member -Name "AttestedSubStatus")
						{
							$isAttestedResult = $true
						}

						if($isAttestedResult)
						{
							$Number_Of_Columns = 7 # ControlID, Status, RG, ResourceName, Control Severity
						}
						else
						{
							$Number_Of_Columns = 6
						}

						$x = 2

						$AzSKReportDoc.Tables.Add($ReportRange,$Number_Of_Controls,$Number_Of_Columns) | Out-Null
						$AzSKReportTable = $AzSKReportDoc.Tables.item(2)

						$AzSKReportTable.Cell(1,1).Range.Text = "ControlId"
						$AzSKReportTable.Cell(1,2).Range.Text = "Status"
						$AzSKReportTable.Cell(1,3).Range.Text = "ResourceGroup"
						$AzSKReportTable.Cell(1,4).Range.Text = "Resource"
						$AzSKReportTable.Cell(1,5).Range.Text = "Severity"
						$AzSKReportTable.Cell(1,6).Range.Text = "Description"
						if($isAttestedResult)
						{
							$AzSKReportTable.Cell(1,7).Range.Text = "Attestation Description"
						}

						Foreach($control in $controls)
						{
							 $AzSKReportTable.Cell($x,1).Range.Text=$control.ControlId
							 $AzSKReportTable.Cell($x,2).Range.Text=$control.Status
							 if($control | Get-Member -Name "ResourceGroupName")
							 {
								$AzSKReportTable.Cell($x,3).Range.Text=$control.ResourceGroupName
								if(($control | Get-Member -Name "ChildResourceName") -and (-Not [string]::IsNullOrEmpty($control.ChildResourceName)))
								{
									$AzSKReportTable.Cell($x,4).Range.Text=$control.ResourceName + "/" + $control.ChildResourceName
								}
								else
								{
									$AzSKReportTable.Cell($x,4).Range.Text=$control.ResourceName
								}
							 }
							 else
							 {
								$isSubscriptionCore = $true
								$AzSKReportTable.Cell($x,3).Range.Text="Subscription"
								$AzSKReportTable.Cell($x,4).Range.Text="Subscription"
							 }
							 $AzSKReportTable.Cell($x,5).Range.Text=$control.ControlSeverity
							 $AzSKReportTable.Cell($x,6).Range.Text=$control.Description
							 $AzSKReportTable.Cell($x,6).Range.Font.Size = 9

							 if($isAttestedResult -and ($control.AttestedSubStatus))
							 {
								#$AzSKReportTable.Cell($x,7).Range.Text=$control.ActualStatus
								$attstionDescription = "Attested Status: " + $control.AttestedSubStatus + "`vAttested By: " + $control.AttestedBy + "`vJustification: " + $control.AttesterJustification
								$AzSKReportTable.Cell($x,7).Range.Text = $attstionDescription
								$AzSKReportTable.Cell($x,7).Range.Font.Size = 9
							 }
							 $x++

							 #if(($control | Get-Member -Name "AttestedSubStatus") -and ($control.AttestedSubStatus))
							 #{
								#$AzSKReportTable.Cell($x,2).Range.Text= "Actual Status : " + $control.ActualStatus

								#$attstionDescription = "Attestation Description`vAttested Status: " + $control.AttestedSubStatus + "`vAttested By: " + $control.AttestedBy + "`vJustification: " + $control.AttesterJustification
								#$AzSKReportTable.Cell($x,6).Range.Text = $attstionDescription
								#$AzSKReportTable.Cell($x,6).Range.Font.Size = 9
								#$x++;
 							# }
						}

						$AzSKReportTable.Style = 'Grid Table 4 - Accent 1'
						$AzSKReportTable.Columns.Autofit()
						$selection = $Word.Selection
						$selection.WholeStory
						$selection.Style = "No Spacing"
						$wdStory = 6
						$wdMove = 0

						$ret = $selection.EndKey($wdStory, $wdMove)
						$selection.TypeParagraph()
						$selection.InsertBreak(7)
					}
				

					#end region

					#region -> Adding PowerShell output

					Get-ChildItem -Path $reportFolderPath -Directory | Where-Object {($_.Name -eq "etc")} | ForEach-Object {
						$rootfolder = $_
						[AzSKPDFExtension]::WriteText($selection, 'PowerShell Output','Heading 1', $false, $true, $false)

						Get-ChildItem -Path $rootfolder.FullName -Recurse -Filter "PowerShellOutput.LOG" | ForEach-Object {
							$logfilepath = $_
							$log = Get-Content $logfilepath.FullName | Out-String
							[AzSKPDFExtension]::WriteText($selection, $log,'No Spacing', $false, $true, $false)
							$selection.TypeText("#################################################################");
							$selection.TypeParagraph()
						}
					}

					$selection.InsertBreak(7)

					#end region -> Adding PowerShell output

					#region -> Adding detailed logs

					[AzSKPDFExtension]::WriteText($selection, 'Detailed Output','Heading 1', $false, $true, $false)
					$selection.InsertBreak(6)

					Get-ChildItem -Path $reportFolderPath -Directory | Where-Object {-not ($_.Name -eq "etc")} | ForEach-Object {
						$rootfolder = $_

						if($isSubscriptionCore)
						{
							[AzSKPDFExtension]::WriteText($selection, 'Subscription Name: '+ ($rootfolder.Name),'Heading 2', $false, $true, $false)
						}
						else
						{
							[AzSKPDFExtension]::WriteText($selection, 'Resource Group Name: ' + ($rootfolder.Name),'Heading 2', $false, $true, $false)
						}
						Get-ChildItem -Path $rootfolder.FullName -Recurse -Filter "*.LOG" | ForEach-Object {
							$logfilepath = $_
							[AzSKPDFExtension]::WriteText($selection, 'Resource Type: ' + ($logfilepath.BaseName),'Heading 3', $false, $true, $false)
							$logs = Get-Content $logfilepath.FullName
							ForEach($log in $logs)
							{
								[AzSKPDFExtension]::WriteText($selection, ($log | Out-String),'No Spacing', $false, $false, $false)
							}

							$selection.TypeParagraph()
							$selection.InsertBreak(7)
						}
					}

					#end region

					# Update table of content
					$toc.Update()
				}
			}
			catch
			{
				throw $_.Exception
			}
			finally
			{
				$wdExportFormatPDF = 17
				$wdDoNotSaveChanges = 0
				$AzSKReportDoc.ExportAsFixedFormat($pdfPath,$wdExportFormatPDF)
				$AzSKReportDoc.close([ref]$wdDoNotSaveChanges)
				$Word.Quit()
				if (test-path variable:AzSKReportDoc)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($AzSKReportDoc) | Out-Null
				}
				if (test-path variable:word)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
				}
				if (test-path variable:range)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($range) | Out-Null
				}
				if (test-path variable:ReportRange)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($ReportRange) | Out-Null
				}
				if (test-path variable:AzSKReportTable)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($AzSKReportTable) | Out-Null
				}
				if (test-path variable:TitleTableRange)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($TitleTableRange) | Out-Null
				}
				if (test-path variable:AzSKTitleTable)
				{
					[System.Runtime.Interopservices.Marshal]::ReleaseComObject($AzSKTitleTable) | Out-Null
				}

				Remove-Variable range
				[gc]::collect()
				[gc]::WaitForPendingFinalizers()
			}
		}
		else
		{
			throw ([SuppressedException]::new(("You must have Microsoft Word application installed on machine to generate PDF report."), [SuppressedExceptionType]::Generic))
		}
	}

	static [void] WriteText([PSObject] $selectionObj, [string] $textToWrite, [string] $style, [bool] $bold, [bool] $newParagraph, [bool] $newLine)
    {
		$selectionObj.TypeText($textToWrite);
		$selectionObj.Style = $style
		if($bold)
		{
			$selectionObj.Range.Font.Bold = 1
		}
		else
		{
			$selectionObj.Range.Font.Bold = 0
		}

		if($newParagraph)
		{
			$selectionObj.TypeParagraph()
		}
		if($newLine)
		{
			$selectionObj.TypeText("`v");
		}
		$selectionObj.WholeStory
		$selectionObj.Style = "No Spacing"
    }

	static [void] WriteHeaderTableCell([PSObject] $tableObj, [int] $row, [string] $title, [string] $value)
    {
		$tableObj.Cell($row,1).Range.Text = $title
		$tableObj.Cell($row,1).Range.Bold = 1
		$tableObj.Cell($row,2).Range.Text = $value
    }
} 