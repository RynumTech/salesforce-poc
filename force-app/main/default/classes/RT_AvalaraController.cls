public without sharing class RT_AvalaraController {

    @AuraEnabled
    public static Map<String, Object> calculateTaxForCart(String cartId) {
        Map<String, Object> summaryResult = new Map<String, Object>();
        
        try {
            if (String.isBlank(cartId)) {
                List<WebCart> activeCarts = [SELECT Id FROM WebCart 
                                             WHERE OwnerId = :UserInfo.getUserId() 
                                             AND (Status = 'Active' OR Status = 'Checkout') 
                                             ORDER BY CreatedDate DESC LIMIT 1];
                if (!activeCarts.isEmpty()) cartId = activeCarts[0].Id;
                else return null;
            }

            WebCart cartHeader = [SELECT TotalChargeAmount FROM WebCart WHERE Id = :cartId LIMIT 1];
            Decimal shipping = (cartHeader.TotalChargeAmount != null) ? cartHeader.TotalChargeAmount : 0;

            Avalara_Config__mdt config = [SELECT Company_Code__c, Ship_From_Street__c, Ship_From_City__c, 
                                          Ship_From_State__c, Ship_From_Zip__c, Ship_From_Country__c 
                                          FROM Avalara_Config__mdt LIMIT 1];

            List<CartDeliveryGroup> groups = [SELECT DeliverToStreet, DeliverToCity, DeliverToState, 
                                              DeliverToPostalCode, DeliverToCountry 
                                              FROM CartDeliveryGroup WHERE CartId = :cartId LIMIT 1];
            
            CartDeliveryGroup deliveryGroup = !groups.isEmpty() ? groups[0] : null;

            // Direct Query for Items
            //sample text 
            List<CartItem> cartItems = [SELECT Id, Name, Quantity, TotalPrice, Product2.Avalara_Tax_Code__c, Product2.ProductCode 
                                        FROM CartItem WHERE CartId = :cartId AND Type = 'Product' AND TotalPrice > 0];

            Decimal calculatedSubtotal = 0;
            Decimal calculatedTax = 0;

            if (!cartItems.isEmpty()) {
                for(CartItem item : cartItems) {
                    if(item.TotalPrice != null) calculatedSubtotal += item.TotalPrice;
                }

                if (deliveryGroup != null) {
                    List<Object> lines = new List<Object>();
                    for (CartItem item : cartItems) {
                        Map<String, Object> lineMap = new Map<String, Object>();
                        lineMap.put('number', item.Id); 
                        lineMap.put('itemCode', item.Product2.ProductCode);
                        lineMap.put('quantity', item.Quantity);
                        lineMap.put('amount', item.TotalPrice);
                        lineMap.put('description', item.Name);
                        lineMap.put('taxCode', String.isBlank(item.Product2.Avalara_Tax_Code__c) ? 'P0000000' : item.Product2.Avalara_Tax_Code__c);
                        lines.add(lineMap);
                    }

                    Map<String, Object> requestBody = new Map<String, Object>{
                        'type' => 'SalesInvoice',
                        'commit' => true,
                        'companyCode' => config.Company_Code__c, 
                        'date' => String.valueOf(Date.today()),
                        'customerCode' => cartId,
                        'currencyCode' => 'USD',
                        'lines' => lines,
                        'addresses' => new Map<String, Object>{
                            'shipTo' => new Map<String, Object>{
                                'line1' => deliveryGroup.DeliverToStreet,
                                'city' => deliveryGroup.DeliverToCity,
                                'region' => deliveryGroup.DeliverToState,
                                'postalCode' => deliveryGroup.DeliverToPostalCode,
                                'country' => deliveryGroup.DeliverToCountry
                            },
                            'shipFrom' => new Map<String, Object>{
                                'line1' => config.Ship_From_Street__c,
                                'city' => config.Ship_From_City__c,
                                'region' => config.Ship_From_State__c,
                                'postalCode' => config.Ship_From_Zip__c,
                                'country' => config.Ship_From_Country__c
                            }
                        }
                    };

                    HttpRequest req = new HttpRequest();
                    req.setEndpoint('callout:Avalara_API/api/v2/transactions/create');
                    req.setMethod('POST');
                    req.setHeader('Content-Type', 'application/json');
                    req.setBody(JSON.serialize(requestBody));

                    Http http = new Http();
                    HttpResponse res = http.send(req);

                    if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                        
                        delete [SELECT Id FROM CartTax WHERE CartId = :cartId];

                        List<Object> responseLines = (List<Object>) parsed.get('lines');
                        List<CartTax> taxesToInsert = new List<CartTax>();

                        if (responseLines != null) {
                            for (Object lineObj : responseLines) {
                                Map<String, Object> lineMap = (Map<String, Object>) lineObj;
                                String itemId = (String) lineMap.get('lineNumber'); 
                                Decimal taxAmt = Decimal.valueOf(String.valueOf(lineMap.get('tax')));
                                calculatedTax += taxAmt;

                                if (taxAmt > 0) {
                                    taxesToInsert.add(new CartTax(
                                        Name = 'Avalara Tax',
                                        CartItemId = itemId, 
                                        Amount = taxAmt,
                                        TaxType = 'Estimated', 
                                        TaxCalculationDate = Date.today()
                                    ));
                                }
                            }
                        }
                        if (!taxesToInsert.isEmpty()) insert taxesToInsert;
                    }
                }
            }

            summaryResult.put('Subtotal', calculatedSubtotal);
            summaryResult.put('Tax', calculatedTax);
            summaryResult.put('Shipping', shipping);
            summaryResult.put('Total', calculatedSubtotal + calculatedTax + shipping);

        } catch (Exception e) {
            System.debug('Tax Error: ' + e.getMessage());
            return null;
        }
        
        return summaryResult;
    }

    @AuraEnabled
    public static Map<String, Object> getCartSummary(String cartId, String check) {
        if (String.isBlank(cartId)) return null;
        
        WebCart cart = [SELECT TotalChargeAmount FROM WebCart WHERE Id = :cartId LIMIT 1];
        Decimal shipping = (cart.TotalChargeAmount != null) ? cart.TotalChargeAmount : 0;

        AggregateResult[] productResults = [SELECT SUM(TotalPrice) sumPrice FROM CartItem WHERE CartId = :cartId AND Type = 'Product'];
        Decimal subtotal = (productResults[0].get('sumPrice') != null) ? (Decimal)productResults[0].get('sumPrice') : 0;

        AggregateResult[] taxResults = [SELECT SUM(Amount) sumTax FROM CartTax WHERE CartId = :cartId];
        Decimal tax = (taxResults[0].get('sumTax') != null) ? (Decimal)taxResults[0].get('sumTax') : 0;

        return new Map<String, Object>{
            'Subtotal' => subtotal,
            'Shipping' => shipping,
            'Tax' => tax,
            'Total' => subtotal + shipping + tax
        };
    }
}