unit PlumbersServer;

// EMS Resource Module

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Hash,
  EMS.Services, EMS.ResourceAPI, EMS.ResourceTypes, FireDAC.Stan.Intf,
  FireDAC.Stan.Option, FireDAC.Stan.Error, FireDAC.UI.Intf, FireDAC.Phys.Intf,
  FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async, FireDAC.Phys,
  FireDAC.Phys.FB, FireDAC.Phys.FBDef, FireDAC.ConsoleUI.Wait,
  FireDAC.Stan.Param, FireDAC.DatS, FireDAC.DApt.Intf, FireDAC.DApt, Data.DB,
  FireDAC.Comp.DataSet, FireDAC.Comp.Client;

type
  [ResourceName('Plumbers')]
  TPlumbersResource1 = class(TDataModule)
    FDPlumDBConnection: TFDConnection;
    FDSelectOrders: TFDQuery;
    FDSelectOrdersInfo: TFDQuery;
    FDSelectPlumbers: TFDQuery;
    FDCheckOperatorAuth: TFDStoredProc;
    FDRegOP: TFDStoredProc;
    FDAddOrder: TFDStoredProc;
    FDAddOrderInfo: TFDStoredProc;
    FDChangeOpEditStatus: TFDStoredProc;
    FDCheckPlumberAuth: TFDStoredProc;
    FDRegPlumber: TFDStoredProc;
    FDUpdatePlumAndOrderStatus: TFDStoredProc;
    FDGetAssignedOrder: TFDStoredProc;
    FDSelectOneOrder: TFDQuery;
    FDSelectOneOrderInfo: TFDQuery;
  published
    procedure Get(const AContext: TEndpointContext; const ARequest: TEndpointRequest; const AResponse: TEndpointResponse);
    procedure Post(const AContext: TEndpointContext; const ARequest: TEndpointRequest; const AResponse: TEndpointResponse);

    function GetDbData(FDQuery: TFDQuery): TJSONObject;
    function GetAllDBData(): TJSONObject;
    procedure UpdatePlumberStatus(PlumberID: integer; Status: string; UpdateMode: Integer);
    procedure UpdateOrderStatus(OrderID: integer; Status: string; UpdateMode: Integer);
    function GetPlumbersAssignedOrder(PlumberID : integer) : TJSONObject;
    function SetDateToPlumbersAssignedOrder(ARequest : TEndpointRequest): TJSONObject;

    function FormJSONResponseMessage(msgtype: string; msg: string): TJSONObject;

    function CheckAccountAuthorization(ARequest: TEndpointRequest; var ID: integer): Boolean;
    function AuthAccount(ARequest: TEndpointRequest): TJSONObject;

    function CheckAccountLoginExists(Login: string; AuthMode: integer): Boolean;
    function RegisterAccount(ARequest: TEndpointRequest): TJSONObject;

    procedure SetOperatorEditStatus(CreatorOpID: integer; EditorOpID: integer);
    function AddOrChangeOrder(ResponseObject : TJSONObject): integer;
    function AddOrChangeOrderInfo(ResponseObject: TJSONObject; AddedOrderID: integer) : integer;
    function AddOrChangeOrderAndOrderInfo(ARequest: TEndpointRequest): TJSONObject;

    function UpdatePlumberOrderStatus(PlumberID: Integer; PlumberStatus: string; OrderID: Integer; OrderStatus: string; UpdateMode: Integer): TJSONObject;
    function AssignPlumberToOrder(ARequest: TEndpointRequest): TJSONObject;
    function DisconnectPlumber(ARequest: TEndpointRequest): TJSONObject;

    function test(ARequest: TEndpointRequest): TJSONObject;
  end;

implementation

{%CLASSGROUP 'System.Classes.TPersistent'}

{$R *.dfm}

function TPlumbersResource1.FormJSONResponseMessage(msgtype: string; msg: string): TJSONObject;
{
  Описание:
    Создаёт JSON-объект ответа сервера, содержащий пару "msgtype" : "msg"
  Параметры:
    1) msgtypе - ключ пары
    2) msg - значение пары
}
begin
  Result:= TJSONObject.Create;
  Result.AddPair(msgtype, msg);
end;


function TPlumbersResource1.CheckAccountAuthorization(ARequest: TEndpointRequest; var ID: integer): Boolean;
{
  Описание:
    Функция проверяет, правильно ли введены данные входа, поступившие с клиента
  Параметры:
    1) ARequest - объект, содержащий запрос от клиента
    2) ID - параметр-переменная, в случае если в базе данных есть данные авторизации пользователя или
    оператора вернёт ID этой записи в базе
  Результат:
    Если данные введены верно, то функция вернёт true, иначе false
}
var
LoginStr, // Логин оператора/сантехника
PasswordStr, // Пароль оператора/сантехника
HashedPassword, // Хэшированный пароль
AuthModeStr: string; // Режим входа. 1 - оператор, 2 - сантехник
StoredProc: TFDStoredProc; // в зависимости от значения AuthMode получит ссылку на объект нужной хранимой
                          // процедуры
AuthMode: integer; // Числовое значение режима входа
begin
  Result:= false;
  ARequest.Params.TryGetValue('login', LoginStr);
  ARequest.Params.TryGetValue('password', PasswordStr);
  ARequest.Params.TryGetValue('mode', AuthModeStr);
  AuthMode:= StrToInt(AuthModeStr);
  HashedPassword:= THashSHA2.GetHashString(PasswordStr);

  case AuthMode of
    1: StoredProc:= FDCheckOperatorAuth;
    2: StoredProc:= FDCheckPlumberAuth;
  end;

  if AuthMode <> 0 then begin
    StoredProc.Prepare;
    StoredProc.ParamByName('in_only_login').Value:= false;
    StoredProc.ParamByName('in_login').Value:= LoginStr;
    StoredProc.ParamByName('in_password').Value:= HashedPassword;
    StoredProc.ExecProc;

    case AuthMode of
      1: ID:= StoredProc.Params.FindParam('out_op_id').AsInteger;
      2: ID:= StoredProc.Params.FindParam('out_plum_id').AsInteger;
    end;

    Result:= StoredProc.Params.FindParam('out_equality').AsBoolean;
  end;
end;

function TPlumbersResource1.GetDbData(FDQuery: TFDQuery): TJSONObject;
{
  Описание:
    Возвращает JSON-объект - представление нужных данных базы для работы оператора
  Параметры:
    1) FDQuery - объект нужного запроса к базе
}
var
dbArrayData: TJSONArray; // JSON-массив объектов, хранимых в таблицах
mainContainer, // возвращаемый объект
dbRow: TJSONObject; // объект представления каждой записи в таблице
columnName: string; // имя столбца в таблице
I: Integer; // переменная-счётчик столбцов запроса
begin
    FDQuery.Open();
    FDQuery.First;
    mainContainer:= TJSONObject.Create;
    dbArrayData:= TJSONArray.Create;
    while (not FDQuery.EOF) do
    begin
      dbRow:= TJSONObject.Create;
      for I := 0 to FDQuery.FieldDefs.Count - 1 do
      begin
        columnName:= FDQuery.FieldDefs[I].Name;
        if (FDQuery.FieldByName(columnName).DataType = ftInteger)
        or (FDQuery.FieldByName(columnName).DataType = ftFloat)
        or (FDQuery.FieldByName(columnName).DataType = ftLargeint)
        or (FDQuery.FieldByName(columnName).DataType = ftLongWord)
        or (FDQuery.FieldByName(columnName).DataType = ftExtended)
        or (FDQuery.FieldByName(columnName).DataType = ftWord) then
            dbRow.AddPair(columnName,
                          TJSONNumber.Create(FDQuery.FieldByName(columnName).AsString))
        else
            dbRow.AddPair(columnName,
                           TJSONString.Create(FDQuery.FieldByName(columnName).AsString));
      end;
      dbArrayData.Add(dbRow);
      dbRow:= TJSONObject.Create;
      FDQuery.Next;
    end;
    FDQuery.Close;
    mainContainer.AddPair('data', dbArrayData);
    Result:= mainContainer;
end;

procedure TPlumbersResource1.UpdatePlumberStatus(PlumberID: integer; Status: string; UpdateMode: Integer);
{
  Описание:
    Присваивает переданный статус сантехнику с переданным ID
}
begin
  FDUpdatePlumAndOrderStatus.Prepare;
  FDUpdatePlumAndOrderStatus.ParamByName('in_plumber_id').Value:= PlumberID;
  FDUpdatePlumAndOrderStatus.ParamByName('in_plumber_status').Value:= Status;
  FDUpdatePlumAndOrderStatus.ParamByName('in_add_mode').Value:= UpdateMode;
  FDUpdatePlumAndOrderStatus.ExecProc;
end;

procedure TPlumbersResource1.UpdateOrderStatus(OrderID: integer; Status: string; UpdateMode: Integer);
{
  Описание:
    Присваивает переданный статус заказу с переданным ID
}
begin
  FDUpdatePlumAndOrderStatus.Prepare;
  FDUpdatePlumAndOrderStatus.ParamByName('in_order_id').Value:= OrderID;
  FDUpdatePlumAndOrderStatus.ParamByName('in_order_status').Value:= Status;
  FDUpdatePlumAndOrderStatus.ParamByName('in_add_mode').Value:= UpdateMode;
  FDUpdatePlumAndOrderStatus.ExecProc;
end;

function TPlumbersResource1.GetPlumbersAssignedOrder(PlumberID : integer) : TJSONObject;
{
  Описание:
    Получает информацию о назначенном заказе для сантехника по ID сантехника.
    Если назначенного заказа нет, то возвращает 0 в поле order_id.
}
var
OrderID: integer;
begin
  Result:= TJSONObject.Create;
  FDGetAssignedOrder.Prepare;
  FDGetAssignedOrder.FindParam('in_plumber_id').Value:= PlumberID;
  FDGetAssignedOrder.ExecProc;

  if FDGetAssignedOrder.FindParam('out_assigned').AsBoolean then begin
    OrderID:= FDGetAssignedOrder.FindParam('out_order_id').AsInteger;

    FDSelectOneOrder.ParamByName('in_id').Value:= OrderID;
    FDSelectOneOrderInfo.ParamByName('in_id').Value:= OrderID;

    Result.AddPair('order', GetDbData(FDSelectOneOrder));
    Result.AddPair('order_info', GetDbData(FDSelectOneOrderInfo));
    Result.AddPair('order_id', TJSONNumber.Create(OrderID));
  end
  else begin
    UpdatePlumberStatus(PlumberID, 'online', 3);
    Result.AddPair('order_id', TJSONNumber.Create(0));
  end;
end;

function TPlumbersResource1.GetAllDBData(): TJSONObject;
{
  Описание:
    Создаёт JSON-объект со всей информацией из базы данных, необходимой для работы оператору:
    - данные сантехников
    - данные о невыполненных заказах
    - данные описания этих заказов
}
var JSONResponse: TJSONObject;
begin
    JSONResponse:= TJSONObject.Create;
    JSONResponse.AddPair('plumbers', GetDbData(FDSelectPlumbers));
    JSONResponse.AddPair('orders', GetDbData(FDSelectOrders));
    JSONResponse.AddPair('ordersinfo', GetDbData(FDSelectOrdersInfo));
    Result:= JSONResponse;
end;

function TPlumbersResource1.AuthAccount(ARequest: TEndpointRequest): TJSONObject;
{
  Описание:
    Авторизует аккаунт.
    Если передаются верные данные входа оператора (AuthMode = 1), то в ответе содержится JSON-объект со всей необходимой
    информацией для обработки на клиенте.
    Если передаются верные данные входа сантехника (AuthMode = 2), то в ответе содежится JSON-объект с информацией о
    заказе, назначенном этому сантехнику.
    Функция используется для обновления данных при повторных запросах.
  Результат:
    JSON-объект, содержащий данные, в зависимости от переданного в параметрах запроса AuthMode в случае
    успеха, иначе объект, содержащий описание ошибки
}
var
ID,
AuthMode: integer;
AuthModeStr: string;
begin
    Result:= TJSONObject.Create;
    if CheckAccountAuthorization(ARequest, ID) then begin
      ARequest.Params.TryGetValue('mode', AuthModeStr);
      AuthMode:= StrToInt(AuthModeStr);
      case AuthMode of
        1: Result:= GetAllDBData();
        2: Result:= GetPlumbersAssignedOrder(ID);
      end;

      Result.AddPair('ID', TJSONNumber.Create(ID));
    end
    else Result:= FormJSONResponseMessage('error', 'Invalid login or password');
end;

function TPlumbersResource1.CheckAccountLoginExists(Login: string; AuthMode: integer): Boolean;
{
  Описание:
    Проверяет, существует ли в базе данных аккаунт оператора/сантехника с переданным логином.
  Параметры:
    1) Login - логин аккаунта
    2) AuthMode - режим авторизации: 1 - оператор, 2 - сантехник
}
var StoredProc: TFDStoredProc;
begin
  Result:= false;

  case AuthMode of
    1: StoredProc:= FDCheckOperatorAuth;
    2: StoredProc:= FDCheckPlumberAuth;
  end;

  if AuthMode <> 0 then begin
    StoredProc.Prepare;
    StoredProc.ParamByName('in_login').Value:= Login;
    StoredProc.ParamByName('in_only_login').Value:= true;
    StoredProc.ExecProc;
    Result:= StoredProc.Params.FindParam('out_equality').AsBoolean;
  end;
end;

function TPlumbersResource1.RegisterAccount(ARequest: TEndpointRequest): TJSONObject;
{
  Описание:
    Функция проверяет, существует ли логин, который желает зарегистрироваться, если нет,
    то создаёт запись в базе с переданными в теле запроса логином и паролем.
  Результат:
    Возвращает JSON-объект, response в случае успеха, error в случае ошибки
}
var
AuthMode: integer;
AccountData: TJSONObject;
Name, Login, Password, AuthModeStr: string;
StoredProc: TFDStoredProc;
begin
  Result:= TJSONObject.Create;
    if ARequest.Body.TryGetObject(AccountData) then begin
      Login:= AccountData.GetValue('login').Value;
      AuthModeStr:= AccountData.GetValue('mode').Value;
      AuthMode:= StrToInt(AuthModeStr);
      if not CheckAccountLoginExists(Login, AuthMode) then begin
        Name:= AccountData.GetValue('name').Value;

        Password:= AccountData.GetValue('password').Value;
        Password:= THashSHA2.GetHashString(Password);

        case AuthMode of
          1: StoredProc:= FDRegOP;
          2: StoredProc:= FDRegPlumber;
        end;

        StoredProc.Prepare;
        StoredProc.ParamByName('in_id').Value:= 0;
        StoredProc.ParamByName('in_name').Value:= Name;
        StoredProc.ParamByName('in_login').Value:= Login;
        StoredProc.ParamByName('in_password').Value:= Password;

        case AuthMode of
          1: StoredProc.ParamByName('in_edit_status').Value:= false;
          2: StoredProc.ParamByName('in_status').Value:= 'offline';
        end;

        StoredProc.ExecProc;
        Result:= FormJSONResponseMessage('response', 'Registration made successfully');
      end
      else Result:= FormJSONResponseMessage('error', 'This login is already used');
    end
    else Result:= FormJSONResponseMessage('error', 'JSON expected');
end;

procedure TPlumbersResource1.SetOperatorEditStatus(CreatorOpID: integer; EditorOpID: integer);
{
  Описание:
    Обновляет статус редактирования заказа другим оператором
  Параметры:
    1) CreatorOpID - ID оператора, создавшего заказ
    2) EditorOpID - ID оператора, редактирующего заказ
}
begin
  if CreatorOpID <> EditorOpID then begin
    FDChangeOpEditStatus.Prepare;
    FDChangeOpEditStatus.ParamByName('in_id').Value:= EditorOpID;
    FDChangeOpEditStatus.ParamByName('in_status').Value:= True;
    FDChangeOpEditStatus.ExecProc;
  end;
end;

function TPlumbersResource1.AddOrChangeOrder(ResponseObject : TJSONObject): integer;
{
  Описание:
    Функция добавляет или изменяет заказ по полученному ID
  Параметры:
    1) ResponseObject - JSON-объект, в котором содержатся поля orderid, operatorid, а также
    JSON-объект с полями заказа. В случае если orderid = 0 создаётся новый заказ, иначе редактируется
    существующий
}
var
OrderData: TJSONObject;
ChangeOrCreateOrderID, OperatorID: integer;
TmpOrderID, TmpOpID: TJSONNumber;
ReceivedDateTime: string;
PlumberID: integer;
begin
  if ResponseObject.TryGetValue('orderid', TmpOrderID) then
    ChangeOrCreateOrderID:= TmpOrderID.Value.ToInteger;
  if ResponseObject.TryGetValue('operatorid', TmpOpID) then
    OperatorID:= TmpOpID.Value.ToInteger;
  Result:= 0;

  if ResponseObject.TryGetValue('orderdata', OrderData) then begin
    FDAddOrder.Prepare;
    FDAddOrder.ParamByName('in_id').Value:= ChangeOrCreateOrderID;

    if ChangeOrCreateOrderID = 0 then
    begin
      OrderData.TryGetValue('creation_date', ReceivedDateTime);
      FDAddOrder.FindParam('in_mode').Value:= 0;
      FDAddOrder.ParamByName('in_creation_date').Value:= ReceivedDateTime;
      FDAddOrder.ParamByName('in_operator_id').Value:= OrderData.GetValue('order_operator_id').Value.ToInteger;
      FDAddOrder.ParamByName('in_status').Value:= 'free';
      FDAddOrder.ExecProc;
      Result:= FDAddOrder.Params.FindParam('out_order_id').AsInteger;
    end
    else begin
      SetOperatorEditStatus(OrderData.GetValue('order_operator_id').Value.ToInteger, OperatorID);
      FDAddOrder.FindParam('in_mode').Value:= 0;

      PlumberID:= OrderData.GetValue('order_plumber_id').Value.ToInteger;
      if PlumberID = 0 then begin
        FDAddOrder.ParamByName('in_status').Value:= 'free';
        UpdatePlumberStatus(PlumberID, 'offline', 3);
      end;
      FDAddOrder.ParamByName('in_plumber_id').Value:= PlumberID;
      FDAddOrder.ExecProc;
      Result:= ChangeOrCreateOrderID;
    end;
  end;
end;

function TPlumbersResource1.AddOrChangeOrderInfo(ResponseObject: TJSONObject; AddedOrderID: integer): integer;
{
  Описание:
    Добавление или изменение информации о заказе.
  Параметры:
    1) ResponseObject - объект, содержащий информационные поля
    2) AddedOrderID - ID добавляемого/изменяемого заказа
  Результат:
    Возвращает ID созданной/изменённой записи информации о заказе.
}
var
OrderInfoData: TJSONObject;
begin
    Result:= 0;
    if ResponseObject.TryGetValue('orderinfodata', OrderInfoData) and (AddedOrderID <> 0) then begin
      FDAddOrderInfo.Prepare;
      FDAddOrderInfo.ParamByName('in_order_id').Value:= AddedOrderID;
      FDAddOrderInfo.ParamByName('in_type').Value:= OrderInfoData.GetValue('type').Value;
      FDAddOrderInfo.ParamByName('in_description').Value:= OrderInfoData.GetValue('description').Value;
      FDAddOrderInfo.ParamByName('in_price').Value:= OrderInfoData.GetValue('price').Value.ToDouble;
      FDAddOrderInfo.ParamByName('in_phone').Value:= OrderInfoData.GetValue('phone').Value.ToInt64;
      FDAddOrderInfo.ParamByName('in_address').Value:= OrderInfoData.GetValue('address').Value;
      FDAddOrderInfo.ExecProc;

      Result:= FDAddOrderInfo.Params.FindParam('out_id').AsInteger;
    end;
end;

function TPlumbersResource1.AddOrChangeOrderAndOrderInfo(ARequest: TEndpointRequest): TJSONObject;
{
  Описание:
    Функция, вызывающая функции создания/изменения заказа и создания/изменения информации о заказе.
  Результат:
    JSON-объект с ответом сервера в случае успеха, иначе объект с описанием ошибки
}
var
ResponseObject: TJSONObject;
AddedOrderID, AddedOrderInfoID: integer;
begin
  ResponseObject:= TJSONObject.Create;

  if ARequest.Body.TryGetObject(ResponseObject) then begin
    AddedOrderID:= AddOrChangeOrder(ResponseObject);
    AddedOrderInfoID:= AddOrChangeOrderInfo(ResponseObject, AddedOrderID);

    if (AddedOrderID <> 0) and (AddedOrderInfoID <> 0) then
      Result:= FormJSONResponseMessage('response', 'New Data added')
    else
      Result:= FormJSONResponseMessage('error', 'Something went wrong');
  end
  else Result:= FormJSONResponseMessage('error', 'JSON expected');

end;

function TPlumbersResource1.UpdatePlumberOrderStatus(PlumberID: Integer; PlumberStatus: string; OrderID: Integer; OrderStatus: string; UpdateMode: Integer): TJSONObject;
{
  Описание:
    Функция вызывает нужную хранимую процедуру, передавая туда ID сантехника, ID заказа и их статусы.
    Причём можно передавать 0 в случае ID и '' в случае статусов, тогда изменения затронут только
    существующие ID или статусы.
}
var
ResponseObject: TJSONObject;
UpdateStatus: Boolean;
begin
  ResponseObject:= TJSONObject.Create;
  FDUpdatePlumAndOrderStatus.Prepare;
  FDUpdatePlumAndOrderStatus.ParamByName('in_order_id').Value:= OrderID;
  FDUpdatePlumAndOrderStatus.ParamByName('in_order_status').Value:= OrderStatus;
  FDUpdatePlumAndOrderStatus.ParamByName('in_plumber_id').Value:= PlumberID;
  FDUpdatePlumAndOrderStatus.ParamByName('in_plumber_status').Value:= PlumberStatus;
  FDUpdatePlumAndOrderStatus.ParamByName('in_add_mode').Value:= UpdateMode;
  FDUpdatePlumAndOrderStatus.ExecProc;

  UpdateStatus:= FDUpdatePlumAndOrderStatus.FindParam('out_updated').AsBoolean;
  if UpdateStatus then Result:= FormJSONResponseMessage('response', 'Status updated')
  else Result:= FormJSONResponseMessage('error', 'Status was not updated');
end;

function TPlumbersResource1.AssignPlumberToOrder(ARequest: TEndpointRequest): TJSONObject;
{
  Описание:
    Назначает сантехника на заказ, для этого передаётся ID сантехника, ID заказа и вызывается функция,
    меняющая статусы сантехнику и заказу.
  Результат:
    JSON-объект с ответом сервера в случае успеха, иначе объект с описанием ошибки
}
var
ResponseObject: TJSONObject;
OrderID, PlumberID: integer;
OrderStatus: string;
begin
  ResponseObject:= TJSONObject.Create;
  if ARequest.Body.TryGetObject(ResponseObject) then begin
    if (ResponseObject.TryGetValue('order_id', OrderID)) and
       (ResponseObject.TryGetValue('plumber_id', PlumberID)) then begin
        Result:= UpdatePlumberOrderStatus(PlumberID, 'assigned', OrderID, 'assigned', 1);
        //
        // вызвать здесь функцию/процедуру, отвечающую за push-уведомления
        //
       end
    else Result:= FormJSONResponseMessage('error', 'Error in parameters');
  end
  else Result:= FormJSONResponseMessage('error', 'JSON expected');
end;

function TPlumbersResource1.SetDateToPlumbersAssignedOrder(ARequest : TEndpointRequest): TJSONObject;
{
  Описание:
    Функция предназначена для обработки действий сантехника из мобильного приложения, а именно, присвоение
    дат прочтения, начала и конца выполнения заказа в информацию о заказе.
  Результат:
    JSON-объект с ответом сервера в случае успеха, иначе объект с описанием ошибки
}
var ResponseObject: TJSONObject;
OrderID, PlumberID: integer;
ActionType, ErrorString, ObjectDate: string;
begin

  if ARequest.Body.TryGetObject(ResponseObject) then begin
    ResponseObject.TryGetValue('date', ObjectDate);
    ResponseObject.TryGetValue('order_id', OrderID);
    ResponseObject.TryGetValue('plumber_id', PlumberID);
    ResponseObject.TryGetValue('action', ActionType);
  end
  else begin
    Result:= FormJSONResponseMessage('error', 'JSON expected');
    Exit;
  end;

    FDAddOrder.Prepare;
    FDAddOrder.FindParam('in_id').Value:= OrderID;

    if ActionType = 'read' then begin
      FDAddOrder.FindParam('in_read_date').Value:= ObjectDate;
      FDAddOrder.FindParam('in_mode').Value:= 1;
      FDAddOrder.ExecProc;
      UpdateOrderStatus(OrderID, 'watched', 2);
      Result:= FormJSONResponseMessage('response', 'Action has correctly executed');
    end
    else
    if ActionType = 'start' then begin
      FDAddOrder.FindParam('in_begin_date').Value:= ObjectDate;
      FDAddOrder.FindParam('in_mode').Value:= 2;
      FDAddOrder.ExecProc;
      UpdateOrderStatus(OrderID, 'processing', 2);
      UpdatePlumberStatus(PlumberID, 'working', 3);
      Result:= FormJSONResponseMessage('response', 'Action has correctly executed');
    end
    else
    if ActionType = 'end' then begin
      FDAddOrder.FindParam('in_end_date').Value:= ObjectDate;
      FDAddOrder.FindParam('in_mode').Value:= 3;
      FDAddOrder.ExecProc;
      UpdateOrderStatus(OrderID, 'completed', 2);
      UpdatePlumberStatus(PlumberID, 'online', 3);
      Result:= FormJSONResponseMessage('response', 'Action has correctly executed');
    end
    else Result:= FormJSONResponseMessage('error', 'Unknown action type');

end;

function TPlumbersResource1.DisconnectPlumber(ARequest: TEndpointRequest): TJSONObject;
{
  Описание:
    Функция предназначена для обработки выхода сантехника из сети
  Результат:
    JSON-объект с ответом сервера в случае успеха, иначе объект с описанием ошибки
}
var
ResponseObject: TJSONObject;
PlumberID: integer;
PlumberOrderStatus: string;
begin
  if ARequest.Body.TryGetObject(ResponseObject) then begin
    if ResponseObject.TryGetValue('plumber_id', PlumberID) and
      ResponseObject.TryGetValue('status', PlumberOrderStatus) then
        if PlumberOrderStatus = 'online' then begin
          UpdatePlumberStatus(PlumberID, 'offline', 3);
          Result:= FormJSONResponseMessage('response', 'Plumber has disconnected');
        end
        else Result:= FormJSONResponseMessage('response', 'Cant set plumber offline')
    else Result:= FormJSONResponseMessage('error', 'Incorrect parameters');
  end
  else Result:= FormJSONResponseMessage('error', 'JSON expected');
end;

function TPlumbersResource1.test(ARequest: TEndpointRequest): TJSONObject;
begin

end;

procedure TPlumbersResource1.Get(const AContext: TEndpointContext; const ARequest: TEndpointRequest; const AResponse: TEndpointResponse);
{
  Описание:
    Здесь происходит обработка вызовов эндпоинтов GET, а именно, обработка авторизации
    сантехников или операторов, получение нужной информации из базы при авторизации
}
var JSONResponse: TJSONObject;
QueryTask: string;
begin
  JSONResponse:= TJSONObject.Create;
  ARequest.Params.TryGetValue('task', QueryTask);

  if QueryTask = 'auth' then JSONResponse:= AuthAccount(ARequest);

  AResponse.Body.SetValue(JSONResponse, True);
end;

procedure TPlumbersResource1.Post(const AContext: TEndpointContext; const ARequest: TEndpointRequest; const AResponse: TEndpointResponse);
{
  Описание:
    Здесь происходит обработка вызовов эндпоинтов POST, а именно, регистрация снтехников/операторов,
    создание и изменение заказа и информации о нём, назначение сантехника на заказ,
    обработка действий мобильного приложения, а также выход из него
}
var JSONResponse: TJSONObject;
DataObject: TJSONObject;
QueryTask: string;
begin
  JSONResponse:= TJSONObject.Create;
  if ARequest.Body.TryGetObject(DataObject) then begin
    if DataObject.TryGetValue('task', QueryTask) then begin
      if QueryTask = 'reg' then JSONResponse:= RegisterAccount(ARequest);
      if QueryTask = 'order' then  JSONResponse:= AddOrChangeOrderAndOrderInfo(ARequest);
      if QueryTask = 'assign' then JSONResponse:= AssignPlumberToOrder(ARequest);
      if QueryTask = 'action' then JSONResponse:= SetDateToPlumbersAssignedOrder(ARequest);
      if QueryTask = 'disconnect' then JSONResponse:= DisconnectPlumber(ARequest);
    end
    else JSONResponse:= FormJSONResponseMessage('error', 'Missing task parameter');
  end
  else JSONResponse:= FormJSONResponseMessage('error', 'JSON expected');

  AResponse.Body.SetValue(JSONResponse, True);
end;

procedure Register;
begin
  RegisterResource(TypeInfo(TPlumbersResource1));
end;

initialization
  Register;
end.


