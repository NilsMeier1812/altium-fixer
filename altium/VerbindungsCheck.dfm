object VCForm: TVCForm
  Left = 300
  Top = 200
  BorderStyle = bsDialog
  Caption = 'Verbindungs-Check - Fixes aus dem Browser holen'
  ClientHeight = 200
  ClientWidth = 460
  Position = poScreenCenter
  PixelsPerInch = 96
  object LabelStatus: TLabel
    Left = 16
    Top = 16
    Width = 428
    Height = 120
    AutoSize = False
    Caption = 'Export fertig. Jetzt im Browser die Fehler anklicken, dann hier "Aenderungen aus dem Browser holen".'
    WordWrap = True
  end
  object ButtonPull: TButton
    Left = 16
    Top = 152
    Width = 300
    Height = 34
    Caption = 'Aenderungen aus dem Browser holen'
    OnClick = ButtonPullClick
  end
  object ButtonClose: TButton
    Left = 332
    Top = 152
    Width = 112
    Height = 34
    Caption = 'Schliessen'
    OnClick = ButtonCloseClick
  end
end
