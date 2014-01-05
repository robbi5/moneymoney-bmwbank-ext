--
-- MoneyMoney Web Banking Extension
-- http://moneymoney-app.com/api/webbanking
--
--
-- The MIT License (MIT)
--
-- Copyright (c) 2014 Maximilian Richt (robbi5)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
--
-- Get balance and transactions for BMW Bank.
--

WebBanking{version     = 1.07,
           country     = "de",
           url         = "https://banking.bmwbank.de/privat",
           description = string.format(MM.localizeText("Get balance and transactions for %s"), "BMW Bank")}


function SupportsBank (protocol, bankCode)
  return bankCode == "70220300" and protocol == ProtocolWebBanking
end

local function strToFullDate (str)
  -- Helper function for converting localized date strings to timestamps.
  local d, m, y = string.match(str, "(%d%d).(%d%d).(%d%d%d%d)")
  return os.time{year=y, month=m, day=d}
end


local function strRemoveSpaces (str)
  -- Helper function for removing spaces from account numbers
  return string.gsub(str, " ", "")
end

local function strTrim (str)
  -- Modified from http://lua-users.org/wiki/StringTrim
  return string.gsub(str, "^%s*(.-)%s*$", "%1")
end

local function strToAmount (str, removeFormatting)
  -- Helper function for converting localized amount strings to Lua numbers.
  local strNew = string.gsub(str, "EUR", "")
  strNew = string.gsub(strNew, "€", "")

  -- Remove spaces
  strNew = strRemoveSpaces(strNew)

  if (removeFormatting == true) then
    strNew = string.gsub(string.gsub(strNew, "%.", ""), ",", ".")
    strNew = string.gsub(strNew, "[^%.%d]", "")
  end

  return strNew
end

-- The following variables are used to save state.
local connection
local html

function InitializeSession (protocol, bankCode, username, customer, password)
  -- Create HTTPS connection object.
  connection = Connection()
  connection.language = "de-de"

  -- Fetch login page.
  html = HTML(connection:get(url))

  -- fill POST body
  local postBody = "&username=" .. username .. "&PASSWORD=" .. password .. "&BUFFER=endl&SMENC=ISO-8859-1&SMLOCALE=DE-DE&SMTOKEN=&smagentname=olb.internet.agent&smauthreason=0&postpreservationdata=&target=/privat&smquerydata=&smtryno=0"
  html = HTML(connection:post("", postBody, "application/x-www-form-urlencoded; charset=UTF-8"))

  -- Check for login error in head/javascript.
  local htmlStr = html:html()
  local badLoginTries = string.match(htmlStr, 'smTryNo%s*=%s*[\'"]([^\'"]+)')
  if badLoginTries and string.len(badLoginTries) > 0 and tonumber(badLoginTries) > 0 then
    return LoginFailed
  end
end


function ListAccounts (knownAccounts)
  local accounts = {}

  -- Navigate to accounts overview page.
  html = HTML(connection:get(url .. '/banking/-?$part=Overview.content.BankAccounts.Overview&$event=init'))

  -- Extract owner name.
  local useridentrow = html:xpath("//div[@id='useridentification']"):text()
  kommapos, dummy = string.find(useridentrow, ",")
  local owner = string.sub(useridentrow, 1, kommapos-1)

  -- Traverse list of accounts
  html:xpath("//table[@class='searchResultTable']//tr[position()>1][position()<last()-1]"):each(function (index, row)
    local columns = row:children()

    -- Extract account number and account name.
    local accountNumber = strRemoveSpaces(columns:get(1):text())
    local name = strRemoveSpaces(columns:get(2):text())

    -- Determine account type.
    local type = AccountTypeUnknown
    if string.find(name, "Spar") then
      type = AccountTypeSavings
    end

    -- Open account details popup to extract IBAN and BIC
    detailPopupHtml = HTML(connection:get(url .. '/banking/-?$part=Overview.content.BankAccounts.Overview&$event=bicIbanAccountDetails&id=' .. accountNumber))

    local iban = detailPopupHtml:xpath("//table[@class='searchResultTablePopUp']//td[contains(@headers,'IBAN')]"):text()
    local bic = detailPopupHtml:xpath("//table[@class='searchResultTablePopUp']//td[contains(@headers,'BIC')]"):text()

    -- Create account object.
    local account = {
      name          = name,
      owner         = owner,
      accountNumber = accountNumber,
      bankCode      = "70220300",
      currency      = "EUR",
      iban          = iban,
      bic           = bic,
      type          = type
    }
    table.insert (accounts, account)

  end)

  return accounts
end

function RefreshAccount (account, since)
  local transactions = nil

  -- Load transaction search page with predefined account number
  html = HTML(connection:get(url .. '/banking/-?$part=Overview.content.BankAccounts.Overview&$event=accountOverviewChangeTurnOverSearch&preAccNo=' .. account.accountNumber))

  -- Set date range
  html:xpath("//input[@id='usedatedropdown']"):attr("checked", "")
  html:xpath("//input[@id='usedaterange']"):attr("checked", "checked")
  -- The from/to dropdowns get merged into hidden input fields with js. just fill them directly
  html:xpath("//input[@id='fromDate']"):attr("value", os.date("%d.%m.%Y", since))
  html:xpath("//input[@id='toDate']"):attr("value", os.date("%d.%m.%Y"))

  -- Show all transactions
  html:xpath("//select[@name='slTablePageSize']"):select(html:xpath("//select[@name='slTablePageSize']/option[contains(text(), 'Alle')]"):attr("value"))

  -- Set $event (hidden)
  html:xpath("//input[@name='$event']"):attr("value", "search")

  print("Submitting transaction search form for " .. account.accountNumber)
  html = HTML(connection:request(html:xpath("//form[@action]"):submit()))

  -- Get Balance from text next to select box
  local balanceString = html:xpath("//table[@id='table-choose-container']//tr[2]/td[2]"):text()
  -- Cut "Verfügbarer Betrag:" away
  local balance = strToAmount(string.sub(strTrim(balanceString), 19, -1), true)

  -- Check if the HTML table with transactions exists.
  if html:xpath("//div[@class='table-transactioncontainer']//table"):length() > 0 then
    transactions = {}

    -- Extract transactions.
    html:xpath("//div[@class='table-transactioncontainer']//table[1]//tr[position()>1]"):each(function (index, row)
      local columns = row:children()

      local transaction = {
        bookingDate = strToFullDate(columns:get(1):text()),
        valueDate   = strToFullDate(columns:get(2):text()),
        name        = columns:get(4):text(),
        purpose     = columns:get(5):text(),
        currency    = "EUR",
        amount      = strToAmount(columns:get(6):text(), true)
      }

      table.insert(transactions, transaction)
    end)

  end

  -- Return balance and array of transactions.
  return {balance=balance, transactions=transactions}
end

function EndSession ()
  -- Navigate to logout page.
  connection:get(url .. '/banking/-?$part=FinanceState.index.privmenu.customermenu&tree=menu&node=8&treeAction=selectNode')
end
