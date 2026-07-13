object VCForm: TVCForm
  Left = 300
  Top = 300
  BorderStyle = bsDialog
  Caption = 'Verbindungs-Check (Altium-Live)'
  ClientHeight = 150
  ClientWidth = 470
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  PixelsPerInch = 96
  TextHeight = 13
  object LabelStatus: TLabel
    Left = 16
    Top = 16
    Width = 438
    Height = 70
    AutoSize = False
    Caption = 'Server startet ...'
    WordWrap = True
  end
  object ButtonStop: TButton
    Left = 16
    Top = 104
    Width = 200
    Height = 30
    Caption = 'Stoppen / Schliessen'
    TabOrder = 0
    OnClick = ButtonStopClick
  end
  object TimerPoll: TTimer
    Interval = 500
    OnTimer = TimerPollTimer
    Left = 408
    Top = 104
  end
end
