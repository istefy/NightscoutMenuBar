//
//  Nightscout.swift
//  NightscoutMenuBar
//
//  Created by Michael Pangburn on 7/28/17.
//  Copyright © 2017 Michael Pangburn. All rights reserved.
//

import Foundation


/// Fetches and stores Nightscout data.
class Nightscout {

    var baseURL: String? = UserDefaults.standard.baseURL {
        didSet {
            UserDefaults.standard.baseURL = baseURL
        }
    }

    var bloodGlucoseEntries: [BloodGlucoseEntry] = []

    var units: BloodGlucoseUnit = .mgdL {
        didSet {
            bloodGlucoseEntries.forEach { $0.units = units }
        }
    }

    enum Result<T> {
        case success(T)
        case failure(Error)
    }

    enum NightscoutError: LocalizedError {
        case invalidURL
        case invalidData
        case dataNotFound
        case unknownResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return NSLocalizedString("Invalid Nightscout URL.", comment: "The error description for an invalid Nightscout URL")
            case .invalidData:
                return NSLocalizedString("Invalid data.", comment: "The error description for invalid data")
            case .dataNotFound:
                return NSLocalizedString("Error code 404: no data found. Verify that your Nightscout URL is correct.", comment: "The error description for a 404 Not Found HTTP response")
            case .unknownResponse(let statusCode):
                return NSLocalizedString("Unknown HTTP response. (Status code: \(statusCode))", comment: "The error description for an unknown HTTP response")
            }
        }
    }
}

// MARK: - Blood glucose data fetching

private let directions = [
    "DoubleUp": "⇈",
    "SingleUp": "↑",
    "FortyFiveUp": "↗",
    "Flat": "→",
    "FortyFiveDown": "↘",
    "SingleDown": "↓",
    "DoubleDown": "⇊"
]

extension Nightscout {

    func fetchBloodGlucoseData(count: Int = 10, completion: @escaping (Result<[BloodGlucoseEntry]>) -> Void) {
        guard let baseURL = baseURL,
            let url = URL(string: "\(baseURL)/api/v1/entries.json?count=\(count)"),
            url.isValid else {
                completion(.failure(NightscoutError.invalidURL))
                return
        }

        let session = URLSession.shared
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("Blood glucose fetch error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    guard let data = data else {
                        completion(.failure(NightscoutError.invalidData))
                        return
                    }
                    do {
                        let bgEntries = try self.bloodGlucoseEntriesFromJSONData(data)
                        completion(.success(bgEntries))
                    } catch {
                        NSLog("BG entry JSON parsing failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                    return
                case 404:
                    completion(.failure(NightscoutError.dataNotFound))
                    return
                default:
                    NSLog("Returned response: %d %@", httpResponse.statusCode, HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
                    completion(.failure(NightscoutError.unknownResponse(httpResponse.statusCode)))
                    return
                }
            }
        }

        task.resume()
    }

    private func bloodGlucoseEntriesFromJSONData(_ data: Data) throws -> [BloodGlucoseEntry] {
        typealias BGEntryDictionary = [String: AnyObject]
        let entryDictionaries: [BGEntryDictionary]

        do {
            entryDictionaries = try JSONSerialization.jsonObject(with: data, options: []) as! [BGEntryDictionary]
        } catch {
            throw error
        }

        var entries: [BloodGlucoseEntry] = []
        for entryDictionary in entryDictionaries {

            // BG value of 12 used when communication is lost
            guard entryDictionary["previousSGVNotActive"] == nil,
                let value = entryDictionary["sgv"] as? Int,
                value != 12 else {
                    continue
            }

            guard let milliseconds = entryDictionary["date"] as? TimeInterval,
                let previousValue = entryDictionary["previousSGV"] as? Int,
                let directionString = entryDictionary["direction"] as? String,
                let direction = directions[directionString] else {
                    throw NightscoutError.invalidData
            }

            let date = Date(timeIntervalSince1970: milliseconds / 1000)
            let entry = BloodGlucoseEntry(date: date, units: units, glucoseValue: value, previousGlucoseValue: previousValue, direction: direction)
            entries.append(entry)
        }
        
        return entries
    }
}


// MARK: - Blood glucose unit fetching
extension Nightscout {

    func updateUnits(completion: (() -> Void)? = nil) {
        fetchUnits() { result in
            switch result {
            case .success(let units):
                self.units = units
                self.bloodGlucoseEntries.forEach { $0.units = units }
            case .failure:
                break
            }
            completion?()
        }
    }

    func fetchUnits(completion: @escaping (Result<BloodGlucoseUnit>) -> Void) {
        guard let baseURL = baseURL,
            let url = URL(string: "\(baseURL)/api/v1/status.json"),
            url.isValid else {
                completion(.failure(NightscoutError.invalidURL))
                return
        }

        let session = URLSession.shared
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("Unit fetch error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200:
                    guard let data = data else {
                        completion(.failure(NightscoutError.invalidData))
                        return
                    }
                    do {
                        let units = try self.bloodGlucoseUnitsFromJSONData(data)
                        completion(.success(units))
                    } catch {
                        NSLog("Unit JSON parsing failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                    return
                case 404:
                    completion(.failure(NightscoutError.dataNotFound))
                    return
                default:
                    NSLog("Returned response: %d %@", httpResponse.statusCode, HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
                    completion(.failure(NightscoutError.unknownResponse(httpResponse.statusCode)))
                    return
                }
            }
        }

        task.resume()
    }

    private func bloodGlucoseUnitsFromJSONData(_ data: Data) throws -> BloodGlucoseUnit {
        let statusDictionary: [String: AnyObject]?
        do {
            statusDictionary = try JSONSerialization.jsonObject(with: data, options: []) as? [String: AnyObject]
        } catch {
            throw error
        }

        guard let statusDict = statusDictionary,
            let settingsDictionary = statusDict["settings"] as? [String: AnyObject],
            let unitString = settingsDictionary["units"] as? String,
            let units = BloodGlucoseUnit(rawValue: unitString) else {
                throw NightscoutError.invalidData
        }
        
        return units
    }
}
