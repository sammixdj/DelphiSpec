unit DelphiSpec.Scenario;

interface

uses
  SysUtils, Classes, Generics.Collections, DelphiSpec.StepDefinitions, DelphiSpec.Attributes,
  DelphiSpec.DataTable, Rtti;

type
  TScenario = class; // forward declaration

  TFeature = class
  private
    FName: string;
    FBackground: TScenario;
    FScenarios: TObjectList<TScenario>;
    FStepDefsClass: TStepDefinitionsClass;
  public
    constructor Create(const Name: string; StepDefsClass: TStepDefinitionsClass); reintroduce;
    destructor Destroy; override;

    property Background: TScenario read FBackground write FBackground;
    property Name: string read FName;
    property Scenarios: TObjectList<TScenario> read FScenarios;
    property StepDefinitionsClass: TStepDefinitionsClass read FStepDefsClass;
  end;

  EScenarioException = class(Exception);
  TScenario = class
  private type
    TStep = class
    strict private
      FValue: string;
      FDataTable: IDelphiSpecDataTable;
    public
      constructor Create(const Value: string; DataTable: IDelphiSpecDataTable); reintroduce;

      property Value: string read FValue;
      property DataTable: IDelphiSpecDataTable read FDataTable;
    end;
  private
    FName: string;
    FFeature: TFeature;

    FGiven: TObjectList<TStep>;
    FWhen: TObjectList<TStep>;
    FThen: TObjectList<TStep>;

    function ConvertDataTable(DataTable: IDelphiSpecDataTable; ParamType: TRttiType): TValue;
    function ConvertParamValue(const Value: string; ParamType: TRttiType): TValue;

    procedure FindStep(Step: TStep; StepDefs: TStepDefinitions; AttributeClass: TDelphiSpecStepAttributeClass);
    function InvokeStep(Step: TStep; StepDefs: TStepDefinitions; AttributeClass: TDelphiSpecStepAttributeClass;
      RttiMethod: TRttiMethod; const Value: string): Boolean;
    function PrepareStep(const Step: string; AttributeClass: TDelphiSpecStepAttributeClass;
      const MethodName: string; const Params: TArray<TRttiParameter>): string;
  public
    constructor Create(Parent: TFeature; const Name: string); reintroduce;
    destructor Destroy; override;

    procedure AddGiven(const Value: string; DataTable: IDelphiSpecDataTable);
    procedure AddWhen(const Value: string; DataTable: IDelphiSpecDataTable);
    procedure AddThen(const Value: string; DataTable: IDelphiSpecDataTable);

    procedure Execute(StepDefs: TStepDefinitions);

    property Feature: TFeature read FFeature;
    property Name: string read FName;
  end;

implementation

uses
  TypInfo, RegularExpressions, TestFramework, StrUtils, Types;

{ TFeature }

constructor TFeature.Create(const Name: string; StepDefsClass: TStepDefinitionsClass);
begin
  inherited Create;
  FName := Name;
  FBackground := nil;
  FScenarios := TObjectList<TScenario>.Create(False);
  FStepDefsClass := StepDefsClass;
end;

destructor TFeature.Destroy;
begin
  FreeAndNil(FBackground);
  FScenarios.Free;
  inherited;
end;

{ TScenario.TScenarioStep }

constructor TScenario.TStep.Create(const Value: string;
  DataTable: IDelphiSpecDataTable);
begin
  inherited Create;
  FValue := Value;
  FDataTable := DataTable;
end;

{ TScenario }

procedure TScenario.AddGiven(const Value: string; DataTable: IDelphiSpecDataTable);
begin
  FGiven.Add(TStep.Create(Value, DataTable));
end;

procedure TScenario.AddThen(const Value: string; DataTable: IDelphiSpecDataTable);
begin
  FThen.Add(TStep.Create(Value, DataTable));
end;

procedure TScenario.AddWhen(const Value: string; DataTable: IDelphiSpecDataTable);
begin
  FWhen.Add(TStep.Create(Value, DataTable));
end;

function TScenario.ConvertParamValue(const Value: string;
  ParamType: TRttiType): TValue;
const
  Delimiter = ',';
var
  Strings: TStringDynArray;
  Values: TArray<TValue>;
  I: Integer;
  ElementType: TRttiType;
begin
  case ParamType.TypeKind of
    TTypeKind.tkInteger: Result := StrToInt(Value);
    TTypeKind.tkInt64: Result := StrToInt64(Value);
    TTypeKind.tkEnumeration:
      Result := TValue.FromOrdinal(ParamType.Handle, GetEnumValue(ParamType.Handle, Value));
    TTypeKind.tkDynArray:
    begin
      Strings := SplitString(Value, Delimiter);
      SetLength(Values, Length(Strings));
      ElementType := (ParamType as TRttiDynamicArrayType).ElementType;
      for I := Low(Strings) to High(Strings) do
        Values[i] := ConvertParamValue(Trim(Strings[I]), ElementType);
      Result := TValue.FromArray(ParamType.Handle, Values);
    end;
  else
    Result := Value;
  end;
end;

constructor TScenario.Create(Parent: TFeature; const Name: string);
begin
  inherited Create;
  FFeature := Parent;
  FName := Name;

  FGiven := TObjectList<TStep>.Create(True);
  FWhen := TObjectList<TStep>.Create(True);
  FThen := TObjectList<TStep>.Create(True);
end;

function TScenario.ConvertDataTable(DataTable: IDelphiSpecDataTable;
  ParamType: TRttiType): TValue;
var
  I: Integer;
  RttiField: TRttiField;
  Values: TArray<TValue>;
  ElementType: TRttiType;
begin
  ElementType := (ParamType as TRttiDynamicArrayType).ElementType;

  SetLength(Values, DataTable.Count);
  for I := 0 to DataTable.Count - 1 do
  begin
    TValue.Make(nil, ElementType.Handle, Values[I]);
    for RttiField in ElementType.AsRecord.GetFields do
      RttiField.SetValue(Values[I].GetReferenceToRawData,
        ConvertParamValue(DataTable[RttiField.Name][I], RttiField.FieldType));
  end;

  Result := TValue.FromArray(ParamType.Handle, Values);
end;

destructor TScenario.Destroy;
begin
  FGiven.Free;
  FWhen.Free;
  FThen.Free;

  inherited;
end;

procedure TScenario.Execute(StepDefs: TStepDefinitions);
var
  Step: TStep;
begin
  for Step in FGiven do
    FindStep(Step, StepDefs, Given_Attribute);

  for Step in FWhen do
    FindStep(Step, StepDefs, When_Attribute);

  for Step in FThen do
    FindStep(Step, StepDefs, Then_Attribute);
end;

procedure TScenario.FindStep(Step: TStep; StepDefs: TStepDefinitions;
  AttributeClass: TDelphiSpecStepAttributeClass);
var
  RttiContext: TRttiContext;
  RttiType: TRttiType;
  RttiMethod: TRttiMethod;
  RttiAttr: TCustomAttribute;
begin
  RttiContext := TRttiContext.Create;
  try
    RttiType := RttiContext.GetType(StepDefs.ClassInfo);

    for RttiMethod in RttiType.GetMethods do
    begin
      for RttiAttr in RttiMethod.GetAttributes do
        if RttiAttr is AttributeClass then
          if InvokeStep(Step, StepDefs, AttributeClass, RttiMethod, TDelphiSpecAttribute(RttiAttr).Text) then
            Exit;

      if StartsText(AttributeClass.Prefix, RttiMethod.Name) then
        if InvokeStep(Step, StepDefs, AttributeClass, RttiMethod, '') then
          Exit;
    end;
  finally
    RttiContext.Free;
  end;

  raise ETestFailure.CreateFmt('Step is not implemented yet: "%s" (%s)', [Step, AttributeClass.ClassName]);
end;

function TScenario.InvokeStep(Step: TStep; StepDefs: TStepDefinitions;
  AttributeClass: TDelphiSpecStepAttributeClass; RttiMethod: TRttiMethod;
  const Value: string): Boolean;
var
  RegExMatch: TMatch;
  I: Integer;
  S: string;
  Params: TArray<TRttiParameter>;
  Values: TArray<TValue>;
begin
  Params := RttiMethod.GetParameters;
  S := PrepareStep(Value, AttributeClass, RttiMethod.Name, Params);
  RegExMatch := TRegEx.Match(Step.Value, S, [TRegExOption.roIgnoreCase]);
  if not RegExMatch.Success then
    Exit(False);

  SetLength(Values, RegExMatch.Groups.Count - 1);
  if Assigned(Step.DataTable) then
  begin
    SetLength(Values, Length(Values) + 1);
    Values[High(Values)] := ConvertDataTable(Step.DataTable, Params[High(Params)].ParamType);
  end;

  if Length(Params) <> Length(Values) then
    raise EScenarioException.CreateFmt('Parameter count does not match: "%s" (%s)', [Step.Value, AttributeClass.ClassName]);

  for I := 0 to RegExMatch.Groups.Count - 2 do
    Values[I] := ConvertParamValue(RegExMatch.Groups[I + 1].Value, Params[I].ParamType);

  RttiMethod.Invoke(StepDefs, Values);
  Result := True;
end;

function TScenario.PrepareStep(const Step: string; AttributeClass: TDelphiSpecStepAttributeClass;
  const MethodName: string; const Params: TArray<TRttiParameter>): string;
var
  I: Integer;
  Prefix: string;
begin
  Result := Step;
  if Result = '' then
  begin
    Prefix := AttributeClass.Prefix;
    if StartsText(Prefix, MethodName) then
    begin
      Result := RightStr(MethodName, Length(MethodName) - Length(Prefix));
      Result := ReplaceStr(Result, '_', ' ');
      for I := 0 to High(Params) do
        Result := TRegEx.Replace(Result, '\b' + Params[I].Name + '\b', '$' + Params[I].Name, [TRegExOption.roIgnoreCase]);
    end;
  end;
  Result := TRegEx.Replace(Result, '(\$[a-zA-Z0-9_]*)', '(.*)');
end;

end.
